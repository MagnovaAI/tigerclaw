//! Runtime registry — binds one `RealRunner` per agent.
//!
//! Where `agent_registry.Registry` is pure config (names, personas,
//! channels), `Runtime` owns the long-lived runners that actually
//! service turns. The two are kept apart on purpose: `Registry` is
//! exercised by config-only tests that should not have to build I/O,
//! providers, or memory plugs; `Runtime` only exists once a process
//! has those things wired.
//!
//! The dispatcher (C5) calls `resolveRunner(envelope.agent_id)` and
//! gets back an `AgentRunner` — same vtable surface as the mock so
//! the call sites do not need to know whether they are talking to
//! the real or the mock impl.
//!
//! Ownership rule: Runtime owns the `*RealRunner` allocations it
//! receives via `register`. On `deinit`, each runner is torn down
//! (which best-effort saves its current session) and freed, then
//! the map itself is freed. The shared memory manager is borrowed
//! and the caller deinits it *after* the Runtime is gone — that
//! way no runner can call `syncTurn` against a torn-down manager
//! during its own shutdown save.

const std = @import("std");

const real_runner_mod = @import("real_runner.zig");
const agent_runner = @import("agent_runner.zig");
const memory = @import("../memory/root.zig");

pub const RegisterError = error{
    OutOfMemory,
    /// A runner with this name was already registered.
    DuplicateName,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    runners: std.StringHashMapUnmanaged(*real_runner_mod.RealRunner) = .{},
    /// Insertion-order list so `deinit` tears runners down in the
    /// order they were registered. Map iteration order is unstable.
    order: std.ArrayList([]const u8),
    memory_manager: *memory.Manager,
    /// Borrowed from the agent registry. Used by `resolveRunner` to
    /// pick the default agent when the caller did not specify one.
    /// Empty string means "no default."
    default_name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        memory_manager: *memory.Manager,
        default_name: []const u8,
    ) Runtime {
        return .{
            .allocator = allocator,
            .order = .empty,
            .memory_manager = memory_manager,
            .default_name = default_name,
        };
    }

    /// Register a runner under `name`. The runtime takes ownership
    /// of the pointer; the caller must have allocated it on the
    /// same allocator passed to `init`. Names must be unique within
    /// a runtime instance.
    pub fn register(
        self: *Runtime,
        name: []const u8,
        runner: *real_runner_mod.RealRunner,
    ) RegisterError!void {
        const gop = try self.runners.getOrPut(self.allocator, name);
        if (gop.found_existing) return RegisterError.DuplicateName;
        gop.value_ptr.* = runner;
        try self.order.append(self.allocator, name);
    }

    pub fn deinit(self: *Runtime) void {
        // Tear runners down in registration order so shutdown logs
        // are deterministic. Each runner.deinit best-effort saves
        // its current session before freeing.
        for (self.order.items) |name| {
            if (self.runners.get(name)) |r| {
                r.deinit();
                self.allocator.destroy(r);
            }
        }
        self.order.deinit(self.allocator);
        self.runners.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Runtime) usize {
        return self.runners.count();
    }

    /// Returns the runner registered under `name`, or null when
    /// unknown.
    pub fn find(self: *const Runtime, name: []const u8) ?*real_runner_mod.RealRunner {
        return self.runners.get(name);
    }

    /// Same selection rule as `agent_registry.Registry.resolveSelector`:
    /// explicit name wins; null falls back to the configured default;
    /// unknown name (or default empty) returns null. Returns the
    /// `AgentRunner` vtable handle ready for the dispatch worker.
    pub fn resolveRunner(self: *Runtime, name_opt: ?[]const u8) ?agent_runner.AgentRunner {
        const name = name_opt orelse self.default_name;
        if (name.len == 0) return null;
        const r = self.runners.get(name) orelse return null;
        return r.runner();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const harness_mod = @import("harness.zig");
const agent_mod = @import("../agent/agent.zig");
const llm = @import("../llm/root.zig");
const vtable_mod = @import("../agent/vtable.zig");
const clock_mod = @import("clock");

/// Spin up one self-contained RealRunner under a tmpdir + tiny
/// builtin memory. Caller owns the returned heap allocation; the
/// caller's Runtime adopts it via `register`.
fn newRunner(
    allocator: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    clock: clock_mod.Clock,
    mock_provider: llm.Provider,
    deny: vtable_mod.ToolExecutor,
    mgr: *memory.Manager,
) !*real_runner_mod.RealRunner {
    const a = try allocator.create(agent_mod.Agent);
    errdefer allocator.destroy(a);
    a.* = agent_mod.Agent.init(.{
        .allocator = allocator,
        .provider = mock_provider,
        .executor = deny,
        .model = .{ .provider = "mock", .model = "0" },
    });

    const r = try allocator.create(real_runner_mod.RealRunner);
    r.* = real_runner_mod.RealRunner.init(.{
        .allocator = allocator,
        .harness = harness_mod.Harness.init(.{
            .allocator = allocator,
            .clock = clock,
            .io = testing.io,
            .state_dir = tmp_dir,
        }),
        .agent = a,
        .memory_manager = mgr,
    });
    return r;
}

test "Runtime: register and resolveRunner round-trip the runner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "hi back", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "concierge",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rt = Runtime.init(testing.allocator, &mgr, "concierge");
    defer rt.deinit();

    const r = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
    try rt.register("concierge", r);

    try testing.expectEqual(@as(usize, 1), rt.count());

    const handle = rt.resolveRunner("concierge").?;
    const result = try handle.run(.{ .session_id = "s1", .input = "hi" });
    try testing.expectEqualStrings("hi back", result.output);
    try testing.expect(result.completed);
}

test "Runtime: resolveRunner with null falls back to default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    const replies = [_]llm.providers.mock.Reply{.{ .text = "ok", .stop_reason = .end_turn }};
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "alpha",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rt = Runtime.init(testing.allocator, &mgr, "alpha");
    defer rt.deinit();

    const r = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
    try rt.register("alpha", r);

    try testing.expect(rt.resolveRunner(null) != null);
}

test "Runtime: resolveRunner returns null for unknown agent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "x",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rt = Runtime.init(testing.allocator, &mgr, "");
    defer rt.deinit();

    try testing.expect(rt.resolveRunner("ghost") == null);
    try testing.expect(rt.resolveRunner(null) == null); // empty default
}

test "Runtime: register rejects a duplicate name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var mock = llm.MockProvider{ .replies = &.{} };
    var deny = vtable_mod.DenyExecutor{};

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "x",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rt = Runtime.init(testing.allocator, &mgr, "");
    defer rt.deinit();

    const r1 = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
    try rt.register("x", r1);

    const r2 = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
    // Tear r2 down ourselves since register is going to refuse it.
    defer {
        r2.deinit();
        testing.allocator.destroy(r2);
    }
    try testing.expectError(RegisterError.DuplicateName, rt.register("x", r2));
}

test "Runtime: deinit tears down every registered runner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var mock = llm.MockProvider{ .replies = &.{} };
    var deny = vtable_mod.DenyExecutor{};

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "shared",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    {
        var rt = Runtime.init(testing.allocator, &mgr, "");
        const a1 = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
        const a2 = try newRunner(testing.allocator, tmp.dir, mc.clock(), mock.provider(), deny.executor(), &mgr);
        try rt.register("a1", a1);
        try rt.register("a2", a2);
        try testing.expectEqual(@as(usize, 2), rt.count());
        rt.deinit();
        // testing.allocator catches any leak from the runners, the
        // map, or the order list.
    }
}
