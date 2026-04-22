//! Gateway daemon lifecycle: build the cross-subsystem values
//! (dispatch queue, channel manager, outbox, allowlist), start the
//! per-channel receive threads, block inside the HTTP accept loop,
//! then drain in a documented order when a shutdown is requested.
//!
//! This module does NOT replace `tcp_server.serve`; it wraps it. All
//! socket handling stays in the server adapter. The value here is the
//! drain ordering, which is load-bearing for correctness — getting
//! the sequence wrong drops in-flight work or joins before it settles.
//!
//! # Drain ordering
//!
//! When `tcp_server.requestStop` flips `should_stop` (SIGTERM handler,
//! `/config/reload` in a future commit, or a test), `serve` returns
//! after its current accept wakes. `run` then proceeds as:
//!
//!   1. Stop accepting new HTTP requests. (Already done — `serve`
//!      returned because `should_stop` was observed between
//!      connections.)
//!   2. Wait for the gateway's in-flight turn counter to reach zero,
//!      bounded by `drain_deadline_ns`. Hanging turns do not veto
//!      shutdown — a timeout logs to stderr and the drain continues.
//!   3. Stop the channel receiver threads. `manager.stop` flips the
//!      shared cancel flag with `.release` and joins every thread, so
//!      no receiver is mid-call when we return.
//!   4. Flush the outbox to disk. Each append already fsyncs and the
//!      receiver threads are the only writers — after the join in
//!      step 3 there is nothing left to flush. The call exists as a
//!      documented contract: "at this point every reply is durable."
//!   5. Close. Ownership returns to the caller, which tears the rest
//!      of the process down.

const std = @import("std");
const builtin = @import("builtin");

const router = @import("router.zig");
const http = @import("http.zig");
const dispatcher = @import("dispatcher.zig");
const tcp_server = @import("tcp_server.zig");
const routes = @import("routes.zig");

const allowlist_mod = @import("../channels/allowlist.zig");
const dispatch_mod = @import("../channels/dispatch.zig");
const manager_mod = @import("../channels/manager.zig");
const outbox_mod = @import("../channels/outbox.zig");
const spec = @import("channels_spec");

const clock_mod = @import("../clock.zig");
const drain_mod = @import("../daemon/drain.zig");

pub const Options = struct {
    address: std.Io.net.IpAddress,
    state_root: std.Io.Dir,
    routes: []const router.Route,
    handlers: dispatcher.HandlerMap,
    /// Clock threaded into the outbox for record timestamps and retry
    /// scheduling. Production wires a wall-clock source; tests inject
    /// `ManualClock` to keep determinism.
    clock: clock_mod.Clock,
    /// Allowlist policy for inbound senders. Defaults to wildcard so
    /// a fresh config admits the local operator; production configs
    /// tighten this to a small list of explicit sender ids.
    allowlist: allowlist_mod.Config = .{ .senders = &.{"*"} },
    /// Soft cap on the dispatch FIFO. Messages over the cap drop the
    /// oldest pending entry — see `channels/dispatch.zig` for the
    /// backpressure contract.
    dispatch_capacity: usize = dispatch_mod.Dispatch.default_capacity,
    /// Drain budget. SIGTERM flips `should_stop`; the drain has at
    /// most this much wall time to wait for in-flight turns before it
    /// proceeds with the manager stop anyway. 30 s mirrors the
    /// default kubelet termination grace period.
    drain_deadline_ns: u64 = 30 * std.time.ns_per_s,
    /// How often the drain loop consults the in-flight predicate.
    /// Small enough that a clean drain finishes promptly; large
    /// enough that a stuck turn does not burn CPU.
    drain_poll_interval_ns: u64 = 10 * std.time.ns_per_ms,
    /// TCP server knobs. Threaded through unchanged so callers can
    /// tune request caps without wedging another Options layer in.
    serve_options: tcp_server.ServeOptions = .{},
};

pub const Boot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: std.Io.net.IpAddress,
    routes: []const router.Route,
    handlers: dispatcher.HandlerMap,
    serve_options: tcp_server.ServeOptions,
    drain_deadline_ns: u64,
    drain_poll_interval_ns: u64,

    dispatch: dispatch_mod.Dispatch,
    manager: manager_mod.Manager,
    outbox: outbox_mod.Outbox,
    allowlist: allowlist_mod.Allowlist,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: Options,
    ) !Boot {
        var dispatch = try dispatch_mod.Dispatch.init(allocator, opts.dispatch_capacity);
        errdefer dispatch.deinit();

        var allowlist = try allowlist_mod.Allowlist.init(allocator, opts.allowlist);
        errdefer allowlist.deinit();

        const outbox = outbox_mod.Outbox.init(io, opts.state_root, allocator, opts.clock);

        var boot: Boot = .{
            .allocator = allocator,
            .io = io,
            .address = opts.address,
            .routes = opts.routes,
            .handlers = opts.handlers,
            .serve_options = opts.serve_options,
            .drain_deadline_ns = opts.drain_deadline_ns,
            .drain_poll_interval_ns = opts.drain_poll_interval_ns,
            .dispatch = dispatch,
            .manager = undefined,
            .outbox = outbox,
            .allowlist = allowlist,
        };
        boot.manager = manager_mod.Manager.init(allocator, io, &boot.dispatch);
        return boot;
    }

    pub fn deinit(self: *Boot) void {
        self.manager.deinit();
        self.allowlist.deinit();
        self.dispatch.deinit();
        self.* = undefined;
    }

    /// Register a channel with the manager. Delegates unchanged; the
    /// boot layer does not own channel lifetimes.
    pub fn addChannel(self: *Boot, channel: spec.Channel) !void {
        try self.manager.add(channel);
    }

    /// Start channel threads, run the gateway accept loop, then drain
    /// in the documented order once `tcp_server.requestStop` flips the
    /// shared flag. Blocks the caller's thread for the duration.
    pub fn run(self: *Boot, ctx: *routes.Context) !void {
        tcp_server.installShutdownHandlers();
        routes.setContext(ctx);
        defer routes.clearContext();

        try self.manager.start();

        // serve blocks until should_stop is observed between
        // connections; the defer below runs whether serve returned
        // cleanly or fell out via error so the drain always fires.
        var serve_err: ?tcp_server.ServeError = null;
        defer self.drain(ctx);

        tcp_server.serve(
            self.allocator,
            self.io,
            &self.address,
            self.routes,
            self.handlers,
            self.serve_options,
        ) catch |err| {
            serve_err = err;
        };

        if (serve_err) |err| return err;
    }

    fn drain(self: *Boot, ctx: *routes.Context) void {
        var wait_ctx: DrainCtx = .{ .counter = ctx.runner.counter() };
        drain_mod.waitFor(self.io, isInFlightZero, &wait_ctx, .{
            .poll_interval_ns = self.drain_poll_interval_ns,
            .deadline_ns = self.drain_deadline_ns,
        }) catch |err| switch (err) {
            error.Timeout => {
                // The user wants the daemon down. A stuck turn does
                // not veto shutdown — we log and move on so a crash
                // loop cannot wedge a pod forever.
                std.debug.print(
                    "gateway: drain timeout after {d}ns with {d} turn(s) in flight; forcing shutdown\n",
                    .{ self.drain_deadline_ns, ctx.runner.counter().current() },
                );
            },
        };

        // Step 3: stop channel receiver threads. Safe even if start
        // was never called — stop is a no-op past the flag flip in
        // that case.
        self.manager.stop();

        // Step 4: flush outbox. Every append already fsyncs and the
        // receivers joined in step 3 were the only writers, so this
        // is a contract anchor rather than an active call.
        _ = self.outbox;
    }
};

const DrainCtx = struct {
    counter: *@import("../harness/agent_runner.zig").InFlightCounter,
};

fn isInFlightZero(raw: ?*anyopaque) bool {
    const ctx: *DrainCtx = @ptrCast(@alignCast(raw.?));
    return ctx.counter.isZero();
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const harness = @import("../harness/root.zig");

/// Minimal channel used to observe whether the manager's receive
/// thread joined on stop. `receive` spins politely until the cancel
/// flag flips, matching the contract the real adapters implement.
const FakeChannel = struct {
    saw_cancel: std.atomic.Value(bool) = .init(false),

    fn channel(self: *FakeChannel) spec.Channel {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn idFn(_: *anyopaque) spec.ChannelId {
        return .telegram;
    }

    fn sendFn(_: *anyopaque, _: spec.OutboundMessage) spec.SendError!void {}

    fn receiveFn(
        ptr: *anyopaque,
        _: []spec.InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) spec.ReceiveError!usize {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        // Poll the cancel flag rather than sleeping — keeps the test
        // deterministic and quick without relying on the Io timer.
        while (!cancel.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        self.saw_cancel.store(true, .release);
        return 0;
    }

    fn deinitFn(_: *anyopaque) void {}

    const vt: spec.Channel.VTable = .{
        .id = idFn,
        .send = sendFn,
        .receive = receiveFn,
        .deinit = deinitFn,
    };
};

fn bootTestOptions(state_root: std.Io.Dir) Options {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    return .{
        .address = addr,
        .state_root = state_root,
        .routes = &routes.routes,
        .handlers = &routes.handlers,
        .clock = (&fixed_test_clock).clock(),
        .drain_deadline_ns = 2 * std.time.ns_per_s,
        .drain_poll_interval_ns = 1 * std.time.ns_per_ms,
    };
}

var fixed_test_clock: clock_mod.FixedClock = .{ .value_ns = 0 };

const RunArgs = struct {
    boot: *Boot,
    ctx: *routes.Context,
    result: ?anyerror = null,
};

fn runBootThread(args: *RunArgs) void {
    args.boot.run(args.ctx) catch |err| {
        args.result = err;
    };
}

test "Boot lifecycle: start, requestStop, drain, manager joined" {
    tcp_server.resetStopForTesting();
    defer tcp_server.resetStopForTesting();

    // Reserve an ephemeral loopback port and release it; serve rebinds
    // via reuse_address. The tiny race is harmless because the test
    // never talks to the port — shutdown is driven by requestStop and
    // a no-op wake connect.
    const probe_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var probe = try probe_addr.listen(testing.io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opts = bootTestOptions(tmp.dir);
    opts.address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;

    var boot = try Boot.init(testing.allocator, testing.io, opts);
    defer boot.deinit();

    var fake: FakeChannel = .{};
    try boot.addChannel(fake.channel());

    var mock = harness.MockAgentRunner.init();
    var ctx: routes.Context = .{ .runner = mock.runner() };

    var args: RunArgs = .{ .boot = &boot, .ctx = &ctx };
    const thread = try std.Thread.spawn(.{}, runBootThread, .{&args});

    // Give serve a moment to bind, then request stop and poke the
    // socket so the parked accept wakes. Retry the wake connect a
    // couple of times in case we raced bind.
    std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    tcp_server.requestStop();
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        if (opts.address.connect(testing.io, .{ .mode = .stream, .protocol = .tcp })) |s| {
            var wake = s;
            wake.close(testing.io);
            break;
        } else |_| {
            std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
    }

    thread.join();

    try testing.expect(args.result == null);
    try testing.expect(fake.saw_cancel.load(.acquire));
}

test "Boot drain times out without crashing when in-flight never zeros" {
    tcp_server.resetStopForTesting();
    defer tcp_server.resetStopForTesting();

    const probe_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var probe = try probe_addr.listen(testing.io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var opts = bootTestOptions(tmp.dir);
    opts.address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    opts.drain_deadline_ns = 100 * std.time.ns_per_ms;

    var boot = try Boot.init(testing.allocator, testing.io, opts);
    defer boot.deinit();

    var mock = harness.MockAgentRunner.init();
    // Start a turn that never ends — the drain predicate stays false
    // for the whole deadline window.
    mock.in_flight.begin();
    defer mock.in_flight.end();
    var ctx: routes.Context = .{ .runner = mock.runner() };

    var args: RunArgs = .{ .boot = &boot, .ctx = &ctx };
    const thread = try std.Thread.spawn(.{}, runBootThread, .{&args});

    std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
    tcp_server.requestStop();
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        if (opts.address.connect(testing.io, .{ .mode = .stream, .protocol = .tcp })) |s| {
            var wake = s;
            wake.close(testing.io);
            break;
        } else |_| {
            std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
    }

    thread.join();
    try testing.expect(args.result == null);
}

test "Boot init/deinit owns its dispatch, manager, allowlist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var boot = try Boot.init(testing.allocator, testing.io, bootTestOptions(tmp.dir));
    boot.deinit();
}
