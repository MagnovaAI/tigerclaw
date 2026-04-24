//! `run` entrypoint.
//!
//! One call: take a user prompt, hand it to a `Provider`, record
//! the resulting turn on a `Session`, and persist the session.
//!
//! This is the thinnest seam between a CLI frontend and the
//! runtime. The react loop (tool-calling, multi-step reasoning)
//! lands in Commit 36 and plugs in here without changing the
//! entrypoint's signature — the loop internally iterates over the
//! same `provider.chat` call this function makes once.
//!
//! Everything the entrypoint touches is injected: allocator,
//! clock, provider, session directory, writer for user-facing
//! output. That makes `run` easy to exercise from a unit test, an
//! E2E test, or a CLI frontend, all without forking code paths.

const std = @import("std");
const types = @import("types");
const clock_mod = @import("clock");
const llm = @import("../llm/root.zig");
const harness = @import("../harness/root.zig");

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    io: std.Io,
    /// Directory that holds `<id>.json` session files.
    state_dir: std.Io.Dir,
    /// The provider to dispatch to. Callers own the impl struct.
    provider: llm.Provider,
    /// Stable session identifier. Caller chooses (typically a
    /// deterministic derivation of the determinism seed so
    /// replays produce identical paths).
    session_id: []const u8,
    /// User input for this single turn.
    user_input: []const u8,
    /// Model to dispatch the provider call to.
    model: types.ModelRef,
    /// Where to write the assistant response for the operator to
    /// see. Tests hand in a `std.Io.Writer.fixed`; the CLI hands
    /// in stdout.
    output: *std.Io.Writer,
    /// If `true` and a session with this id already exists, load
    /// it and append the new turn. Otherwise start fresh.
    resume_if_exists: bool = false,
};

pub const RunResult = struct {
    /// Number of committed turns after this run (≥ 1).
    turn_count: u32,
    /// Bytes of assistant text that were written to `output`.
    bytes_written: usize,
    /// Token usage reported by the provider, for the caller's
    /// ledger bookkeeping.
    usage: types.TokenUsage,
};

pub fn run(opts: RunOptions) !RunResult {
    var h = harness.harness.Harness.init(.{
        .allocator = opts.allocator,
        .clock = opts.clock,
        .io = opts.io,
        .state_dir = opts.state_dir,
    });

    var session = if (opts.resume_if_exists) blk: {
        if (h.resumeSession(opts.session_id)) |s| {
            break :blk s;
        } else |err| switch (err) {
            error.FileNotFound => break :blk try h.startSession(opts.session_id),
            else => return err,
        }
    } else try h.startSession(opts.session_id);
    defer session.deinit();

    // Build the provider request. We pass zero prior messages for
    // this commit — the react loop will feed the real history in.
    const messages: []const types.Message = &.{};
    const req = llm.ChatRequest{
        .messages = messages,
        .model = opts.model,
    };

    const response = try opts.provider.chat(opts.allocator, req);
    defer if (response.text) |t| opts.allocator.free(t);

    const assistant_text = response.text orelse "";
    try session.appendTurn(opts.user_input, assistant_text);
    try h.saveSession(&session);

    try opts.output.writeAll(assistant_text);
    // Delimit so batched callers can pipe responses into a log
    // without losing turn boundaries.
    try opts.output.writeAll("\n");

    return .{
        .turn_count = session.turnCount(),
        .bytes_written = assistant_text.len + 1,
        .usage = response.usage,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "run: single turn with a mock provider round-trips through the session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const reply = llm.providers.mock.Reply{ .text = "hello back" };
    const replies = [_]llm.providers.mock.Reply{reply};
    var mock = llm.MockProvider{ .replies = &replies };

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const result = try run(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
        .provider = mock.provider(),
        .session_id = "e2e-1",
        .user_input = "hi",
        .model = .{ .provider = "mock", .model = "0" },
        .output = &out,
    });

    try testing.expectEqual(@as(u32, 1), result.turn_count);
    try testing.expectEqualStrings("hello back\n", out.buffered());
}

test "run: resume_if_exists appends to the stored history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "r1" },
        .{ .text = "r2" },
    };
    var mock = llm.MockProvider{ .replies = &replies };

    var mc = clock_mod.ManualClock{ .value_ns = 100 };
    var out_buf: [256]u8 = undefined;

    // First call starts the session.
    {
        var out: std.Io.Writer = .fixed(&out_buf);
        const r = try run(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
            .provider = mock.provider(),
            .session_id = "grow",
            .user_input = "q1",
            .model = .{ .provider = "mock", .model = "0" },
            .output = &out,
            .resume_if_exists = true,
        });
        try testing.expectEqual(@as(u32, 1), r.turn_count);
    }

    mc.advance(50);

    // Second call with the same id and resume_if_exists extends
    // the history to 2.
    {
        var out: std.Io.Writer = .fixed(&out_buf);
        const r = try run(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
            .provider = mock.provider(),
            .session_id = "grow",
            .user_input = "q2",
            .model = .{ .provider = "mock", .model = "0" },
            .output = &out,
            .resume_if_exists = true,
        });
        try testing.expectEqual(@as(u32, 2), r.turn_count);
    }
}
