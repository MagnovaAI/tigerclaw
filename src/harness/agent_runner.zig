//! AgentRunner vtable + in-flight turn counter.
//!
//! The gateway never talks to an agent loop directly — it calls into
//! the `AgentRunner` vtable defined here. A mock impl is used for
//! gateway integration tests and early CLI work; the real react-loop
//! impl lands alongside the agent subsystem in a later commit.
//!
//! `InFlightCounter` is a thread-safe atomic counter. The gateway
//! increments it at the start of a turn and decrements at the end;
//! the SIGTERM drain path calls `waitZero` to block until no turns
//! are in flight. Lock-free on the fast path; the zero-wait path uses
//! a `std.Thread.ResetEvent` so sleepers wake on the last decrement.
//!
//! The vtable is pure: no imports across subsystems, no reliance on
//! global state, allocator-passed. Concrete impls own their own
//! session state; the vtable only describes the turn surface.

const std = @import("std");

// --- in-flight counter -----------------------------------------------------

pub const InFlightCounter = struct {
    count: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn init() InFlightCounter {
        return .{};
    }

    /// Mark the start of a turn. Consumers must pair each `begin`
    /// with exactly one `end`.
    pub fn begin(self: *InFlightCounter) void {
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    /// Mark the end of a turn.
    pub fn end(self: *InFlightCounter) void {
        const prev = self.count.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    pub fn current(self: *const InFlightCounter) u32 {
        return self.count.load(.acquire);
    }

    pub fn isZero(self: *const InFlightCounter) bool {
        return self.current() == 0;
    }
};

// Drain loop (poll `counter.isZero()` with bounded timeout) lives in
// the daemon commit so this module has no dependency on `Io`.

// --- AgentRunner vtable ----------------------------------------------------

/// Incremental-delta callback surfaced on every text fragment the
/// runner produces during a turn. The gateway's streaming path sets
/// this so text flows to the HTTP client before the turn completes;
/// callers that don't care leave both fields null and the runner
/// degrades to end-of-turn delivery.
pub const StreamSink = *const fn (ctx: ?*anyopaque, fragment: []const u8) void;

/// Phase reported to `ToolEventSink`. `started` fires before the
/// runner dispatches the tool; `progress` may fire any number of
/// times during long-running dispatches (currently bash); `finished`
/// fires once when the tool returns. A failure during dispatch still
/// terminates with `finished` — the rendered output carries the
/// error reason so the client can show it.
pub const ToolEventPhase = enum { started, progress, finished };

/// Started payload. `args_summary` is a tool-specific one-line
/// preview the consumer can render in the "tool fired" pill (for
/// example, the bash command). Empty when the runner has nothing
/// useful to say upfront.
pub const ToolStartedPayload = struct {
    id: []const u8,
    name: []const u8,
    args_summary: []const u8 = "",
};

/// Progress chunk surfaced mid-dispatch. Phase 9 (TUI streaming)
/// consumes these; the gateway path is free to ignore them.
pub const ToolProgressPayload = struct {
    id: []const u8,
    stream: enum { stdout, stderr },
    chunk: []const u8,
};

/// Finished payload. `kind` carries the tool-shaped result; consumers
/// that only deal with text can read `kind.text` (always populated as
/// a flat preview, even when a richer variant is also set).
pub const ToolFinishedPayload = struct {
    id: []const u8,
    name: []const u8,
    kind: ToolFinishedKind,
    /// True when the tool dispatch threw or returned a tool_result
    /// block flagged is_error. Lets the TUI paint the bullet red
    /// without having to pattern-match on rendered text.
    is_error: bool = false,
};

/// Tagged union of per-tool result shapes. Every variant carries a
/// flat-text view (`text` field on the inner struct, or the `text`
/// arm itself) so naive consumers don't need to switch on variant.
pub const ToolFinishedKind = union(enum) {
    /// Generic / unknown tool. The `text` slice is the rendered
    /// tool_result body verbatim.
    text: []const u8,
    /// Tool was skipped or aborted because the user pressed ESC.
    /// `text` is the marker we surfaced to the model as the
    /// synthetic tool_result; the TUI renders it dimmed so the
    /// row visually distinguishes "tool cancelled" from "tool
    /// completed".
    cancelled: []const u8,
    bash: BashFinished,
    read: ReadFinished,
    glob: GlobFinished,
    grep: GrepFinished,
    web_search: WebSearchFinished,
    todo_write: TodoWriteFinished,

    /// Flat text view, suitable for the gateway's SSE serializer or
    /// any client that doesn't care about the structured shape.
    pub fn flatText(self: ToolFinishedKind) []const u8 {
        return switch (self) {
            .text => |t| t,
            .cancelled => |t| t,
            .bash => |b| b.text,
            .read => |r| r.text,
            .glob => |g| g.text,
            .grep => |g| g.text,
            .web_search => |w| w.text,
            .todo_write => |t| t.text,
        };
    }
};

pub const BashFinished = struct {
    text: []const u8,
    command: []const u8 = "",
    exit_code: i32 = 0,
    interrupted: bool = false,
    duration_ms: u64 = 0,
};

pub const ReadFinished = struct {
    text: []const u8,
    path: []const u8 = "",
    /// One of `text`, `unchanged`, `empty`, `past_eof`.
    variant: enum { text, unchanged, empty, past_eof } = .text,
    num_lines: u32 = 0,
    total_lines: u32 = 0,
};

pub const GlobFinished = struct {
    text: []const u8,
    pattern: []const u8 = "",
    match_count: u32 = 0,
    truncated: bool = false,
};

pub const GrepFinished = struct {
    text: []const u8,
    pattern: []const u8 = "",
    file_count: u32 = 0,
    match_count: u32 = 0,
    truncated: bool = false,
};

pub const WebSearchFinished = struct {
    text: []const u8,
    query: []const u8 = "",
    result_count: u32 = 0,
};

pub const TodoWriteFinished = struct {
    text: []const u8,
    pending: u32 = 0,
    in_progress: u32 = 0,
    done: u32 = 0,
};

/// Tagged-union event passed to `ToolEventSink`.
pub const ToolEvent = union(ToolEventPhase) {
    started: ToolStartedPayload,
    progress: ToolProgressPayload,
    finished: ToolFinishedPayload,
};

/// Event callback for tool-use turns. Each tool call the runner
/// dispatches invokes this sink at least twice: once on `.started`,
/// once on `.finished`, with optional `.progress` events in between.
/// All slices on the event are borrowed for the duration of the
/// call; consumers that need to hold them past the sink invocation
/// must dupe.
pub const ToolEventSink = *const fn (
    ctx: ?*anyopaque,
    event: ToolEvent,
) void;

pub const TurnRequest = struct {
    /// Opaque session identifier. Concrete impls may parse this into
    /// a (`agent_name`, `channel_id`, `conversation_key`) triple.
    session_id: []const u8,
    /// User-facing message; the runner is free to augment with
    /// system prompts, tool results, etc.
    input: []const u8,
    /// Optional per-turn text sink. When set, the runner fires
    /// `stream_sink(stream_sink_ctx, fragment)` for every text
    /// fragment the provider streams back. The slice is borrowed
    /// for the duration of the call only.
    stream_sink: ?StreamSink = null,
    stream_sink_ctx: ?*anyopaque = null,
    /// Optional per-turn tool-event sink. Fires on start and end of
    /// each tool dispatch the runner performs. Shares `sink_ctx`
    /// with the text sink when set on the same turn; callers that
    /// want the two sinks wired to different contexts can set
    /// `tool_event_sink_ctx` separately.
    tool_event_sink: ?ToolEventSink = null,
    tool_event_sink_ctx: ?*anyopaque = null,
};

pub const TurnResult = struct {
    /// Final assistant output after the turn completes. May be empty
    /// if the turn is ongoing (streaming impls).
    output: []const u8,
    /// True when the turn completed without being cancelled.
    completed: bool,
};

pub const TurnError = error{
    SessionMissing,
    BudgetExceeded,
    Cancelled,
    Interrupted,
    InternalError,
    OutOfMemory,
};

pub const TurnId = u64;

pub const VTable = struct {
    /// Run a single turn to completion. Returning the result synchronously.
    /// Streaming impls will use `runStreaming` (added in a later commit);
    /// this blocking form covers the mock and the CLI happy path.
    run: *const fn (ctx: *anyopaque, req: TurnRequest) TurnError!TurnResult,
    /// Request cancellation of the given turn. Idempotent; a concrete
    /// impl may return `Cancelled` from `run` in response.
    cancel: *const fn (ctx: *anyopaque, turn_id: TurnId) void,
    /// Returns the counter the gateway increments/decrements per turn.
    /// Exposing it through the vtable lets the dispatch and the
    /// drain path share a single counter across impls.
    counter: *const fn (ctx: *anyopaque) *InFlightCounter,
};

pub const AgentRunner = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn run(self: AgentRunner, req: TurnRequest) TurnError!TurnResult {
        return self.vtable.run(self.ctx, req);
    }

    pub fn cancel(self: AgentRunner, turn_id: TurnId) void {
        self.vtable.cancel(self.ctx, turn_id);
    }

    pub fn counter(self: AgentRunner) *InFlightCounter {
        return self.vtable.counter(self.ctx);
    }
};

// --- mock impl -------------------------------------------------------------

/// A minimal AgentRunner the gateway uses until the real react-loop
/// impl lands. Echoes the request input back as the output, counts
/// turns via the shared `InFlightCounter`, and treats every `cancel`
/// call as a no-op.
pub const MockAgentRunner = struct {
    in_flight: InFlightCounter,
    /// Canned reply prefix. Result body is `reply_prefix ++ input`.
    reply_prefix: []const u8 = "mock: ",

    pub fn init() MockAgentRunner {
        return .{ .in_flight = InFlightCounter.init() };
    }

    pub fn runner(self: *MockAgentRunner) AgentRunner {
        return .{ .ctx = self, .vtable = &mock_vtable };
    }
};

const mock_vtable: VTable = .{
    .run = mockRun,
    .cancel = mockCancel,
    .counter = mockCounter,
};

fn mockRun(ctx: *anyopaque, req: TurnRequest) TurnError!TurnResult {
    const self: *MockAgentRunner = @ptrCast(@alignCast(ctx));
    self.in_flight.begin();
    defer self.in_flight.end();

    if (req.session_id.len == 0) return error.SessionMissing;

    // The mock does not allocate; it returns a slice that aliases the
    // input. The real impl will return an owned string; both shapes
    // fit `[]const u8` in `TurnResult`.
    return .{ .output = req.input, .completed = true };
}

fn mockCancel(_: *anyopaque, _: TurnId) void {}

fn mockCounter(ctx: *anyopaque) *InFlightCounter {
    const self: *MockAgentRunner = @ptrCast(@alignCast(ctx));
    return &self.in_flight;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "InFlightCounter: begin/end round-trip" {
    var c = InFlightCounter.init();
    try testing.expectEqual(@as(u32, 0), c.current());
    c.begin();
    try testing.expectEqual(@as(u32, 1), c.current());
    c.begin();
    try testing.expectEqual(@as(u32, 2), c.current());
    c.end();
    c.end();
    try testing.expectEqual(@as(u32, 0), c.current());
}

test "InFlightCounter: isZero reports the transition to zero" {
    var c = InFlightCounter.init();
    try testing.expect(c.isZero());
    c.begin();
    try testing.expect(!c.isZero());
    c.end();
    try testing.expect(c.isZero());
}

test "InFlightCounter: counter is atomically shared across threads" {
    var c = InFlightCounter.init();

    const Worker = struct {
        fn run(counter: *InFlightCounter) void {
            counter.begin();
            counter.end();
        }
    };

    // Spawn a handful of short workers and confirm the counter is
    // zero once they all finish.
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&c});
    for (threads) |t| t.join();

    try testing.expect(c.isZero());
}

test "MockAgentRunner: run echoes the input with the counter round-tripping" {
    var mock = MockAgentRunner.init();
    const r = mock.runner();

    const result = try r.run(.{ .session_id = "s1", .input = "hello" });
    try testing.expect(result.completed);
    try testing.expectEqualStrings("hello", result.output);

    try testing.expectEqual(@as(u32, 0), r.counter().current());
}

test "MockAgentRunner: run with empty session returns SessionMissing" {
    var mock = MockAgentRunner.init();
    const r = mock.runner();
    try testing.expectError(
        error.SessionMissing,
        r.run(.{ .session_id = "", .input = "x" }),
    );
}

test "AgentRunner vtable: cancel is a no-op on the mock" {
    var mock = MockAgentRunner.init();
    const r = mock.runner();
    r.cancel(42);
    try testing.expectEqual(@as(u32, 0), r.counter().current());
}
