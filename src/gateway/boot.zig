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
const settings_mod = @import("../settings/root.zig");
const env_overrides = @import("../settings/env_overrides.zig");

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
    /// Path to the settings file, relative to `state_root`. Read once
    /// at init and re-read on every `/config/reload`. Missing or
    /// malformed files do not abort startup — the runtime begins on
    /// defaults and the reload path logs the failure.
    config_path: []const u8 = "config.json",
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

    state_root: std.Io.Dir,
    config_path: []const u8,
    /// Live settings value. Overwritten by `rebuild`; readers never
    /// touch this field directly — they go through `active_snapshot`
    /// so the pointer swap is the only synchronisation point.
    current_settings: settings_mod.Settings,
    /// Every published snapshot, in publish order. Each `rebuild`
    /// heap-allocates a fresh `SettingsSnapshot` and appends it here
    /// before swapping `active_snapshot` to its address. The reason
    /// old snapshots stick around until `deinit` is that an in-flight
    /// request may still be reading one — without RCU / hazard
    /// pointers we cannot free eagerly, and the memory cost is
    /// trivial (one small struct per reload).
    snapshots: std.array_list.Aligned(*routes.SettingsSnapshot, null),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: Options,
    ) !Boot {
        var dispatch = try dispatch_mod.Dispatch.init(allocator, opts.dispatch_capacity);
        errdefer dispatch.deinit();

        var allowlist = try allowlist_mod.Allowlist.init(allocator, opts.allowlist);
        errdefer allowlist.deinit();

        var outbox = try outbox_mod.Outbox.init(io, opts.state_root, allocator, opts.clock);
        errdefer outbox.deinit();

        const initial_settings = loadSettings(allocator, io, opts.state_root, opts.config_path) orelse
            settings_mod.schema.defaultSettings();

        var snapshots: std.array_list.Aligned(*routes.SettingsSnapshot, null) = .empty;
        errdefer snapshots.deinit(allocator);
        const initial_snap = try allocator.create(routes.SettingsSnapshot);
        errdefer allocator.destroy(initial_snap);
        initial_snap.* = .{
            .settings = initial_settings,
            .generation = routes.reload_generation.load(.monotonic),
        };
        try snapshots.append(allocator, initial_snap);

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
            .state_root = opts.state_root,
            .config_path = opts.config_path,
            .current_settings = initial_settings,
            .snapshots = snapshots,
        };
        boot.manager = manager_mod.Manager.init(allocator, io, &boot.dispatch);
        return boot;
    }

    /// Re-read the settings file and publish a fresh snapshot. Best
    /// effort: a missing or malformed file leaves the previously
    /// published snapshot in place so an operator typo can't knock the
    /// daemon off a valid config. Called synchronously from the
    /// reload handler before the generation bump, so the generation
    /// the new snapshot stamps matches what the HTTP client observes
    /// on the next `/health` poll.
    pub fn rebuild(self: *Boot) void {
        const next = loadSettings(self.allocator, self.io, self.state_root, self.config_path) orelse {
            std.debug.print(
                "gateway: config reload failed (missing or invalid {s}); keeping previous settings\n",
                .{self.config_path},
            );
            return;
        };

        const snap = self.allocator.create(routes.SettingsSnapshot) catch {
            std.debug.print("gateway: config reload out of memory; keeping previous settings\n", .{});
            return;
        };
        // The generation stamped here matches the value external
        // pollers will see on the next `/health`: the route handler
        // bumps the counter immediately after this callback returns.
        snap.* = .{
            .settings = next,
            .generation = routes.reload_generation.load(.monotonic) + 1,
        };
        self.snapshots.append(self.allocator, snap) catch {
            self.allocator.destroy(snap);
            std.debug.print("gateway: config reload out of memory; keeping previous settings\n", .{});
            return;
        };

        self.current_settings = next;
        routes.setActiveSnapshot(snap);
    }

    pub fn deinit(self: *Boot) void {
        self.manager.deinit();
        self.allowlist.deinit();
        self.dispatch.deinit();
        self.outbox.deinit();
        for (self.snapshots.items) |s| self.allocator.destroy(s);
        self.snapshots.deinit(self.allocator);
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

        // Publish the initial snapshot and wire the rebuild callback
        // before taking the accept loop. Tests that exercise the route
        // handler directly go through the same path, so the snapshot
        // is always present for an in-flight request.
        routes.setActiveSnapshot(self.snapshots.items[self.snapshots.items.len - 1]);
        defer routes.clearActiveSnapshot();
        ctx.reload_callback = bootRebuildAdapter;
        ctx.reload_userdata = self;

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

fn bootRebuildAdapter(userdata: ?*anyopaque) void {
    const self: *Boot = @ptrCast(@alignCast(userdata.?));
    self.rebuild();
}

/// Read `config_path` under `state_root` and parse into a Settings
/// value. Returns null on any failure (missing file, I/O error, parse
/// error, validation failure) so callers can treat every non-success
/// outcome uniformly. `Settings` holds no allocator-backed slices, so
/// copying the parsed value out of the parse arena is safe.
fn loadSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: std.Io.Dir,
    config_path: []const u8,
) ?settings_mod.Settings {
    const file = state_root.openFile(io, config_path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    const len = file.length(io) catch return null;
    if (len == 0) return settings_mod.schema.defaultSettings();

    const bytes = allocator.alloc(u8, @intCast(len)) catch return null;
    defer allocator.free(bytes);

    var r_buf: [1024]u8 = undefined;
    var r = file.reader(io, &r_buf);
    r.interface.readSliceAll(bytes) catch return null;

    var env: env_overrides.MapLookup = .{ .entries = &.{} };
    var report = settings_mod.loader.loadFromBytes(allocator, bytes, env.lookup()) catch return null;
    defer report.deinit();
    return report.value();
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

test "Boot.rebuild republishes the snapshot as the config file changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Settings A — non-default values so we can tell A apart from the
    // built-in defaults and from B.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data =
        \\{"log_level":"warn","mode":"bench","max_tool_iterations":7,"max_history_messages":42,"monthly_budget_cents":1000}
        ,
    });

    var boot = try Boot.init(testing.allocator, testing.io, bootTestOptions(tmp.dir));
    defer boot.deinit();

    routes.clearActiveSnapshot();
    defer routes.clearActiveSnapshot();

    const gen_before = routes.reload_generation.load(.monotonic);

    boot.rebuild();

    const snap_a = routes.activeSnapshot() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(settings_mod.schema.LogLevel.warn, snap_a.settings.log_level);
    try testing.expectEqual(settings_mod.schema.Mode.bench, snap_a.settings.mode);
    try testing.expectEqual(@as(u32, 7), snap_a.settings.max_tool_iterations);
    try testing.expectEqual(gen_before + 1, snap_a.generation);

    // Overwrite with Settings B.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data =
        \\{"log_level":"debug","mode":"run","max_tool_iterations":3,"max_history_messages":11,"monthly_budget_cents":50}
        ,
    });

    // Simulate the HTTP handler's post-callback counter bump so the
    // second rebuild stamps a strictly-greater generation, mirroring
    // production ordering where `configReloadHandler` bumps after the
    // callback returns.
    _ = routes.reload_generation.fetchAdd(1, .monotonic);
    boot.rebuild();

    const snap_b = routes.activeSnapshot() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(settings_mod.schema.LogLevel.debug, snap_b.settings.log_level);
    try testing.expectEqual(@as(u32, 3), snap_b.settings.max_tool_iterations);
    try testing.expect(snap_b.generation > snap_a.generation);
}

test "Boot.rebuild leaves the previous snapshot alone on malformed config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{\"log_level\":\"warn\",\"max_tool_iterations\":5}",
    });

    var boot = try Boot.init(testing.allocator, testing.io, bootTestOptions(tmp.dir));
    defer boot.deinit();

    routes.clearActiveSnapshot();
    defer routes.clearActiveSnapshot();

    boot.rebuild();
    const good = routes.activeSnapshot() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(settings_mod.schema.LogLevel.warn, good.settings.log_level);
    const good_ptr = good;
    const good_gen = good.generation;
    const good_level = good.settings.log_level;

    // Now corrupt the file. The reload should log (to stderr via
    // std.debug.print) and leave `active_snapshot` pointing at the
    // same snapshot object with the same contents.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{not json at all",
    });

    boot.rebuild();
    const after = routes.activeSnapshot() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(good_ptr, after);
    try testing.expectEqual(good_gen, after.generation);
    try testing.expectEqual(good_level, after.settings.log_level);
}
