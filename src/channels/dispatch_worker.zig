//! Dispatch worker — the thread that makes `Manager → Agent → Outbox`
//! one continuous path.
//!
//! The manager's per-channel receive threads push `InboundMessage`
//! values into a shared `Dispatch` FIFO. Nothing drains that FIFO on
//! its own; this module is what pulls from the queue, runs one agent
//! turn per message, and appends the reply to the outbox so the
//! sender thread can actually deliver it.
//!
//! # Responsibility split
//!
//! * Manager receive thread → enqueue `InboundMessage` (one per
//!   channel, fully owns its lifecycle).
//! * Dispatch worker (THIS MODULE) → dequeue → runner.run → outbox.append.
//! * Outbox sender thread (separate module) → read outbox → channel.send.
//!
//! Each of those threads has exactly one job. Splitting it this way
//! means provider latency cannot stall receive, and a Telegram send
//! timeout cannot block the provider call.
//!
//! # Error handling
//!
//! A runner error is logged and the turn is dropped — no reply goes
//! to the outbox, but dispatch keeps running. Outbox append failures
//! are logged; the message is lost. Both of these are data-loss paths
//! on purpose: the alternative is letting the queue wedge because one
//! agent is misconfigured.

const std = @import("std");

const dispatch_mod = @import("dispatch.zig");
const outbox_mod = @import("outbox.zig");
const spec = @import("channels_spec");
const agent_runner = @import("../harness/agent_runner.zig");

const log = std.log.scoped(.dispatch_worker);

pub const Worker = struct {
    allocator: std.mem.Allocator,
    dispatch: *dispatch_mod.Dispatch,
    outbox: *outbox_mod.Outbox,
    runner: agent_runner.AgentRunner,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        dispatch: *dispatch_mod.Dispatch,
        outbox: *outbox_mod.Outbox,
        runner: agent_runner.AgentRunner,
    ) Worker {
        return .{
            .allocator = allocator,
            .dispatch = dispatch,
            .outbox = outbox,
            .runner = runner,
        };
    }

    pub fn start(self: *Worker) std.Thread.SpawnError!void {
        if (self.thread != null) return;
        self.cancel.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Flip the cancel flag and join the worker thread. Safe if
    /// `start` was never called. The queue may have unprocessed
    /// entries when this returns — callers that care should drain
    /// the manager (stop its receive threads) before calling us.
    pub fn stop(self: *Worker) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

fn loop(self: *Worker) void {
    while (!self.cancel.load(.acquire)) {
        const msg = self.dispatch.dequeue(&self.cancel) orelse return;
        processOne(self, msg) catch |err| {
            log.warn("turn failed for agent={s}: {s}", .{
                msg.agent_name,
                @errorName(err),
            });
        };
    }
}

const TurnError = anyerror;

fn processOne(self: *Worker, msg: spec.InboundMessage) TurnError!void {
    // Route to the runner keyed by agent name. `AgentRegistry` uses
    // session_id as the routing field in v0.1.0; we pass agent_name
    // there so the registry can look the right loaded agent up.
    const req: agent_runner.TurnRequest = .{
        .session_id = msg.agent_name,
        .input = msg.text,
    };

    const result = self.runner.run(req) catch |err| {
        // Turn errors are terminal for this message. Log and drop;
        // the outbox stays clean so a retry won't double-send.
        return err;
    };
    if (!result.completed) {
        log.info("dispatch: turn returned incomplete for agent={s}", .{msg.agent_name});
        return;
    }
    if (result.output.len == 0) return; // nothing to reply with

    // Fan the reply out to the outbox. The sender thread picks it up
    // from here; we don't block on the wire.
    const record_id = self.outbox.append(msg.channel_id, .{
        .conversation_key = msg.conversation_key,
        .thread_key = msg.thread_key,
        .text = result.output,
    }) catch |err| {
        log.warn("dispatch: outbox append failed: {s}", .{@errorName(err)});
        return err;
    };
    // Append returns a caller-owned id the sender would use to ack;
    // we don't track it here (the sender walks the outbox by cursor
    // order, not by id).
    self.allocator.free(record_id);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock");

/// Stub runner: records what it saw and echoes input back with a prefix.
const StubRunner = struct {
    in_flight: agent_runner.InFlightCounter = .init(),
    last_session: ?[]const u8 = null,
    last_input: ?[]const u8 = null,
    canned_reply: []const u8 = "stub reply",
    fail: bool = false,
    calls: std.atomic.Value(u32) = .init(0),

    fn runner(self: *StubRunner) agent_runner.AgentRunner {
        return .{ .ctx = self, .vtable = &vt };
    }

    fn runFn(ctx: *anyopaque, req: agent_runner.TurnRequest) agent_runner.TurnError!agent_runner.TurnResult {
        const self: *StubRunner = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.last_session = req.session_id;
        self.last_input = req.input;
        if (self.fail) return agent_runner.TurnError.InternalError;
        return .{ .output = self.canned_reply, .completed = true };
    }
    fn cancelFn(_: *anyopaque, _: agent_runner.TurnId) void {}
    fn counterFn(ctx: *anyopaque) *agent_runner.InFlightCounter {
        const self: *StubRunner = @ptrCast(@alignCast(ctx));
        return &self.in_flight;
    }
    const vt: agent_runner.VTable = .{ .run = runFn, .cancel = cancelFn, .counter = counterFn };
};

test "worker: inbound message → runner call → outbox append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var outbox = try outbox_mod.Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    defer outbox.deinit();

    var stub: StubRunner = .{ .canned_reply = "pong" };

    var worker = Worker.init(testing.allocator, &dispatch, &outbox, stub.runner());
    try worker.start();
    defer worker.stop();

    // Push one message; the worker should pick it up, call the stub,
    // and land a record in outbox/telegram.jsonl.
    const msg: spec.InboundMessage = .{
        .upstream_id = 1,
        .channel_id = .telegram,
        .agent_name = "tiger",
        .conversation_key = "chat-42",
        .sender_id = "user-1",
        .text = "ping",
    };
    _ = dispatch.enqueue(msg);

    // Spin until the runner has observed the call (up to ~2s wall).
    var waited_ns: u64 = 0;
    while (stub.calls.load(.acquire) == 0 and waited_ns < 2_000_000_000) : (waited_ns += 5_000_000) {
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    try testing.expect(stub.calls.load(.acquire) == 1);
    try testing.expectEqualStrings("tiger", stub.last_session.?);
    try testing.expectEqualStrings("ping", stub.last_input.?);

    // Wait for the outbox append to flush. The worker holds no locks
    // we care about, so a short sleep is enough.
    waited_ns = 0;
    while (waited_ns < 1_000_000_000) : (waited_ns += 5_000_000) {
        var cur = try outbox.cursor(.telegram);
        defer cur.deinit();
        if (try cur.next()) |p| {
            try testing.expectEqualStrings("pong", p.text);
            try testing.expectEqualStrings("chat-42", p.conversation_key);
            return;
        }
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    return error.TestOutboxNeverPopulated;
}

test "worker: runner error drops the message and keeps going" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();
    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var outbox = try outbox_mod.Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    defer outbox.deinit();

    var stub: StubRunner = .{ .fail = true };
    var worker = Worker.init(testing.allocator, &dispatch, &outbox, stub.runner());
    try worker.start();
    defer worker.stop();

    _ = dispatch.enqueue(.{
        .upstream_id = 1,
        .channel_id = .telegram,
        .agent_name = "tiger",
        .conversation_key = "c",
        .sender_id = "u",
        .text = "err",
    });

    var waited_ns: u64 = 0;
    while (stub.calls.load(.acquire) == 0 and waited_ns < 2_000_000_000) : (waited_ns += 5_000_000) {
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    try testing.expect(stub.calls.load(.acquire) == 1);

    // Outbox must still be empty — a failed turn never produces a reply.
    var cur = try outbox.cursor(.telegram);
    defer cur.deinit();
    try testing.expect(try cur.next() == null);
}
