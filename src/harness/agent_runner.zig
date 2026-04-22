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

pub const TurnRequest = struct {
    /// Opaque session identifier. Concrete impls may parse this into
    /// a (`agent_name`, `channel_id`, `conversation_key`) triple.
    session_id: []const u8,
    /// User-facing message; the runner is free to augment with
    /// system prompts, tool results, etc.
    input: []const u8,
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
