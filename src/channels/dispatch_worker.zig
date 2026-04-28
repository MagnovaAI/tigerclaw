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
const runtime_mod = @import("../harness/runtime.zig");

const log = std.log.scoped(.dispatch_worker);

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn elapsedMs(started_ns: i128) u64 {
    const now = monotonicNowNs();
    if (now <= started_ns) return 0;
    return @intCast(@divTrunc(now - started_ns, std.time.ns_per_ms));
}

fn threadKey(value: ?[]const u8) []const u8 {
    return value orelse "-";
}

/// Worker can be wired to either a single runner (legacy / mock /
/// CLI single-agent path) or a runtime registry (production
/// multi-agent path). The choice is made at construction time and
/// stable for the worker's lifetime; per-message routing reads
/// `agent_name` from the envelope and looks the runner up against
/// whichever source is wired.
pub const RunnerSource = union(enum) {
    single: agent_runner.AgentRunner,
    runtime: *runtime_mod.Runtime,

    /// Resolve the runner for a given agent name. Returns null when
    /// the runtime has no registration for the name (callers log and
    /// drop the message).
    pub fn resolve(self: RunnerSource, agent_name: []const u8) ?agent_runner.AgentRunner {
        return switch (self) {
            .single => |r| r,
            .runtime => |rt| rt.resolveRunner(agent_name),
        };
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    dispatch: *dispatch_mod.Dispatch,
    outbox: *outbox_mod.Outbox,
    source: RunnerSource,
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
            .source = .{ .single = runner },
        };
    }

    /// Construct a worker that routes per-message via a Runtime
    /// registry. The worker borrows the runtime for its lifetime;
    /// caller deinits the runtime *after* the worker stops.
    pub fn initWithRuntime(
        allocator: std.mem.Allocator,
        dispatch: *dispatch_mod.Dispatch,
        outbox: *outbox_mod.Outbox,
        rt: *runtime_mod.Runtime,
    ) Worker {
        return .{
            .allocator = allocator,
            .dispatch = dispatch,
            .outbox = outbox,
            .source = .{ .runtime = rt },
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
        const stats = self.dispatch.stats();
        log.info("dispatch dequeued channel={s} agent={s} conversation={s} thread={s} sender={s} upstream={d} text_bytes={d} queue_enqueued={d} queue_drained={d} queue_dropped={d} queue_in_flight={d}", .{
            @tagName(msg.channel_id),
            msg.agent_name,
            msg.conversation_key,
            threadKey(msg.thread_key),
            msg.sender_id,
            msg.upstream_id,
            msg.text.len,
            stats.enqueued,
            stats.drained,
            stats.dropped,
            self.dispatch.inFlight(),
        });
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
    // Route to the runner keyed by agent name. With a Runtime
    // source, a missing registration is a deny — log and drop, do
    // not crash the worker so one misconfigured agent_name in the
    // queue does not poison every message behind it.
    const runner = self.source.resolve(msg.agent_name) orelse {
        log.warn("dispatch: no runner registered for agent={s}; dropping", .{msg.agent_name});
        return;
    };

    const started_ns = monotonicNowNs();
    self.dispatch.beginTurn();
    defer self.dispatch.endTurn();

    log.info("turn start channel={s} agent={s} session={s} conversation={s} thread={s} sender={s} upstream={d} queue_in_flight={d}", .{
        @tagName(msg.channel_id),
        msg.agent_name,
        msg.agent_name,
        msg.conversation_key,
        threadKey(msg.thread_key),
        msg.sender_id,
        msg.upstream_id,
        self.dispatch.inFlight(),
    });
    const req: agent_runner.TurnRequest = .{
        .session_id = msg.agent_name,
        .input = msg.text,
    };

    const result = runner.run(req) catch |err| {
        // Turn errors are terminal for this message. Log and drop;
        // the outbox stays clean so a retry won't double-send.
        return err;
    };
    if (!result.completed) {
        log.info("turn incomplete channel={s} agent={s} session={s} duration_ms={d}", .{
            @tagName(msg.channel_id),
            msg.agent_name,
            msg.agent_name,
            elapsedMs(started_ns),
        });
        return;
    }
    log.info("turn complete channel={s} agent={s} session={s} completed={} output_bytes={d} duration_ms={d} queue_in_flight={d}", .{
        @tagName(msg.channel_id),
        msg.agent_name,
        msg.agent_name,
        result.completed,
        result.output.len,
        elapsedMs(started_ns),
        self.dispatch.inFlight(),
    });
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
    log.info("outbox queued channel={s} agent={s} conversation={s} thread={s} record_id={s} reply_bytes={d} turn_duration_ms={d}", .{
        @tagName(msg.channel_id),
        msg.agent_name,
        msg.conversation_key,
        threadKey(msg.thread_key),
        record_id,
        result.output.len,
        elapsedMs(started_ns),
    });
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
        return .{
            .output = self.canned_reply,
            .completed = true,
            .turn_epoch = req.turn_epoch,
            .dispatch_kind = req.dispatch_kind,
            .invoker = req.invoker,
            .target_agent = if (req.target_agent.len != 0) req.target_agent else req.session_id,
            .mention_order_idx = req.mention_order_idx,
        };
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

test "worker: unknown agent_name with a Runtime source drops without crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();
    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var outbox = try outbox_mod.Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    defer outbox.deinit();

    // Build a stubbed Manager + empty Runtime — no runners, so any
    // agent_name resolves to null and the worker should drop.
    const memory = @import("../memory/root.zig");
    const RuntimeStub = struct {
        fn provider(self: *@This()) memory.Provider {
            return .{ .ptr = self, .vtable = &vt, .kind = .builtin, .name = "stub" };
        }
        fn initFn(_: *anyopaque) memory.MemoryError!void {}
        fn sysFn(_: *anyopaque) memory.MemoryError![]const u8 {
            return "";
        }
        fn prefetchFn(_: *anyopaque, _: []const u8) memory.MemoryError!memory.provider.Prefetch {
            return .{ .text = "" };
        }
        fn syncFn(_: *anyopaque, _: memory.provider.TurnPair) memory.MemoryError!void {}
        fn shutdownFn(_: *anyopaque) void {}
        const vt: memory.provider.VTable = .{
            .initialize = initFn,
            .system_prompt_block = sysFn,
            .prefetch = prefetchFn,
            .sync_turn = syncFn,
            .shutdown = shutdownFn,
        };
    };
    var stub: RuntimeStub = .{};
    var mgr = memory.Manager.init(testing.allocator, stub.provider());
    defer mgr.deinit();
    var rt = runtime_mod.Runtime.init(testing.allocator, &mgr, "");
    defer rt.deinit();

    var worker = Worker.initWithRuntime(testing.allocator, &dispatch, &outbox, &rt);
    try worker.start();
    defer worker.stop();

    _ = dispatch.enqueue(.{
        .upstream_id = 1,
        .channel_id = .telegram,
        .agent_name = "ghost",
        .conversation_key = "c",
        .sender_id = "u",
        .text = "hi",
    });

    // The worker logs and drops; outbox stays empty. Wait briefly
    // for the dispatch round-trip to complete.
    var waited_ns: u64 = 0;
    while (waited_ns < 500_000_000) : (waited_ns += 5_000_000) {
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    var cur = try outbox.cursor(.telegram);
    defer cur.deinit();
    try testing.expect(try cur.next() == null);
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
