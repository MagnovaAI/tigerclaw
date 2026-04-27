//! Plug lifecycle: register → start → drain → stop.
//!
//! Lifecycle is the state machine that takes a set of Manifests and
//! drives them through the four phases the runtime needs:
//!
//!   1. register  — verify manifests, run topological sort, build the
//!                  initial Registry snapshot. Pure side-effect-free.
//!   2. start     — activate each plug in topological order, calling
//!                  its onStart hook. Partial failure rolls back: any
//!                  already-started plug is stopped in reverse order.
//!   3. drain     — stop accepting new work; finish in-flight work up
//!                  to a caller-provided deadline. Plugs declare their
//!                  readiness via onDrain.
//!   4. stop      — release resources. Reverse of start order.
//!
//! The lifecycle does NOT own the Registry; callers pass one in. This
//! keeps plug-activation and registry-management as orthogonal
//! concerns and makes lifecycle easy to test.
//!
//! Hooks are vtable-like function pointers on each plug:
//!   - onStart(ctx, impl)  called once at start
//!   - onDrain(ctx, impl, deadline_ms) called once at drain
//!   - onStop(ctx, impl)   called once at stop
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.lifecycle

const std = @import("std");
const capabilities = @import("capabilities.zig");
const manifest_mod = @import("manifest.zig");
const dep_graph = @import("dep_graph.zig");
const registry_mod = @import("registry.zig");
const context_mod = @import("context");
const errors = @import("errors.zig");

const Capability = capabilities.Capability;
const Manifest = manifest_mod.Manifest;
const Registry = registry_mod.Registry;
const Context = context_mod.Context;
const PlugError = errors.PlugError;

/// A lifecycle-aware plug bundle. One per manifest; wrap your plug's
/// vtable (providers/channels/memory/etc.) with these hooks to
/// participate in lifecycle.
pub const PlugHandle = struct {
    manifest: Manifest,
    impl: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onStart: ?*const fn (impl: *anyopaque, ctx: *const Context) PlugError!void = null,
        onDrain: ?*const fn (impl: *anyopaque, ctx: *const Context, deadline_ms: i64) PlugError!void = null,
        onStop: ?*const fn (impl: *anyopaque, ctx: *const Context) void = null,
    };
};

pub const Phase = enum { idle, registered, started, draining, stopped };

pub const InstallSnapshotError = std.mem.Allocator.Error || error{
    VtableVersionMismatch,
    ExclusiveSlotConflict,
};

/// Lifecycle state machine. Owns the topological order of plugs and
/// tracks which phase they're in.
pub const Lifecycle = struct {
    alloc: std.mem.Allocator,
    plugs: []const PlugHandle,
    order: []const usize,
    phase: Phase = .idle,
    started_count: usize = 0,

    pub fn init(alloc: std.mem.Allocator, plugs: []const PlugHandle) !Lifecycle {
        var manifests = try alloc.alloc(Manifest, plugs.len);
        defer alloc.free(manifests);
        for (plugs, 0..) |p, i| manifests[i] = p.manifest;

        const order = try dep_graph.topoSort(alloc, manifests);
        errdefer alloc.free(order);

        return .{
            .alloc = alloc,
            .plugs = plugs,
            .order = order,
            .phase = .registered,
        };
    }

    pub fn deinit(self: *Lifecycle) void {
        self.alloc.free(self.order);
    }

    /// Build the initial Registry snapshot containing every plug's
    /// capability entry and install it atomically. Must be called
    /// AFTER start has run so implementations are live.
    pub fn installSnapshot(self: *Lifecycle, reg: *Registry) InstallSnapshotError!void {
        std.debug.assert(self.phase == .started);

        var entry_count: usize = 0;
        for (self.order) |i| {
            entry_count += self.plugs[i].manifest.provides.len;
        }

        const entries = try self.alloc.alloc(registry_mod.Entry, entry_count);
        defer self.alloc.free(entries);

        var occupied = [_]bool{false} ** capabilities.capability_count;
        var exclusive_owner = [_]?[]const u8{null} ** capabilities.capability_count;
        var idx: usize = 0;
        for (self.order) |i| {
            const p = self.plugs[i];
            for (p.manifest.provides) |cap| {
                if (p.manifest.vtable_version != capabilities.currentVtableVersion(cap)) {
                    return error.VtableVersionMismatch;
                }

                const tag = cap.tag();
                if (p.manifest.slot == .exclusive and occupied[tag]) {
                    return error.ExclusiveSlotConflict;
                }
                if (p.manifest.slot != .exclusive and exclusive_owner[tag] != null) {
                    return error.ExclusiveSlotConflict;
                }
                if (p.manifest.slot == .exclusive) {
                    exclusive_owner[tag] = p.manifest.id;
                }
                occupied[tag] = true;

                entries[idx] = .{
                    .capability = cap,
                    .plug_id = p.manifest.id,
                    .vtable_ver = p.manifest.vtable_version,
                    .impl = p.impl,
                };
                idx += 1;
            }
        }

        const snap = try registry_mod.buildSnapshot(reg, self.alloc, entries[0..idx]);
        reg.swap(snap);
    }

    /// Start each plug in topological order. On failure, already-
    /// started plugs are stopped in reverse order and the error is
    /// returned.
    pub fn start(self: *Lifecycle, ctx: *const Context) PlugError!void {
        std.debug.assert(self.phase == .registered);
        self.started_count = 0;
        errdefer self.rollbackStart(ctx);

        for (self.order) |i| {
            const p = self.plugs[i];
            if (p.vtable.onStart) |f| {
                try f(p.impl, ctx);
            }
            self.started_count += 1;
        }
        self.phase = .started;
    }

    fn rollbackStart(self: *Lifecycle, ctx: *const Context) void {
        // Stop plugs we already started, in reverse of start order.
        var i: usize = self.started_count;
        while (i > 0) {
            i -= 1;
            const p = self.plugs[self.order[i]];
            if (p.vtable.onStop) |f| f(p.impl, ctx);
        }
        self.started_count = 0;
        self.phase = .registered;
    }

    /// Drain in-flight work up to `deadline_ms`. Each plug is given a
    /// chance to finish work; if any plug returns Timeout, drain
    /// continues for the rest but the caller receives Timeout at end.
    pub fn drain(self: *Lifecycle, ctx: *const Context, deadline_ms: i64) PlugError!void {
        std.debug.assert(self.phase == .started);
        self.phase = .draining;

        var any_timeout = false;
        // Drain in reverse of start order: plugs that depend on others
        // drain first.
        var i: usize = self.started_count;
        while (i > 0) {
            i -= 1;
            const p = self.plugs[self.order[i]];
            if (p.vtable.onDrain) |f| {
                f(p.impl, ctx, deadline_ms) catch |e| switch (e) {
                    error.Timeout => any_timeout = true,
                    else => return e,
                };
            }
        }

        if (any_timeout) return error.Timeout;
    }

    /// Stop each plug in reverse start order. Non-failing — plugs get
    /// one chance to tear down; errors are not propagated (stop must
    /// always proceed).
    pub fn stop(self: *Lifecycle, ctx: *const Context) void {
        std.debug.assert(self.phase == .draining or self.phase == .started);
        var i: usize = self.started_count;
        while (i > 0) {
            i -= 1;
            const p = self.plugs[self.order[i]];
            if (p.vtable.onStop) |f| f(p.impl, ctx);
        }
        self.started_count = 0;
        self.phase = .stopped;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Dep = manifest_mod.Dep;
const Slot = registry_mod.Slot;
const clock_mod = @import("clock");

// A trivial plug used in tests. Records how many times each hook fired
// so we can assert ordering.
const TestPlug = struct {
    start_called: usize = 0,
    drain_called: usize = 0,
    stop_called: usize = 0,
    fail_on_start: bool = false,
    fail_on_drain: bool = false,

    fn onStart(impl: *anyopaque, _: *const Context) PlugError!void {
        const self: *TestPlug = @ptrCast(@alignCast(impl));
        self.start_called += 1;
        if (self.fail_on_start) return error.Internal;
    }

    fn onDrain(impl: *anyopaque, _: *const Context, _: i64) PlugError!void {
        const self: *TestPlug = @ptrCast(@alignCast(impl));
        self.drain_called += 1;
        if (self.fail_on_drain) return error.Timeout;
    }

    fn onStop(impl: *anyopaque, _: *const Context) void {
        const self: *TestPlug = @ptrCast(@alignCast(impl));
        self.stop_called += 1;
    }

    const vtable = PlugHandle.VTable{
        .onStart = onStart,
        .onDrain = onDrain,
        .onStop = onStop,
    };
};

fn mkManifest(id: []const u8, provides: []const Capability, deps: []const Dep) Manifest {
    return .{
        .id = id,
        .version = "2026.04.23",
        .provides = provides,
        .deps = deps,
        .slot = .shared,
    };
}

fn mkTestContext(clk: *const clock_mod.Clock) Context {
    return .{
        .io = undefined,
        .alloc = testing.allocator,
        .clock = clk,
        .trace_id = std.mem.zeroes(context_mod.TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "session:test",
        .origin_channel_id = null,
    };
}

test "lifecycle: start → stop hits every plug once in order" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_clock = TestPlug{};
    var p_meter = TestPlug{};

    const plugs = [_]PlugHandle{
        .{
            .manifest = mkManifest("meter-tokens", &[_]Capability{.meter}, &[_]Dep{.{ .capability = .clock, .kind = .requires }}),
            .impl = @ptrCast(&p_meter),
            .vtable = &TestPlug.vtable,
        },
        .{
            .manifest = mkManifest("clock-system", &[_]Capability{.clock}, &.{}),
            .impl = @ptrCast(&p_clock),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    try lc.start(&ctx);
    try testing.expectEqual(@as(usize, 1), p_clock.start_called);
    try testing.expectEqual(@as(usize, 1), p_meter.start_called);
    try testing.expectEqual(@as(usize, 2), lc.started_count);

    try lc.drain(&ctx, 1000);
    try testing.expectEqual(@as(usize, 1), p_clock.drain_called);
    try testing.expectEqual(@as(usize, 1), p_meter.drain_called);

    lc.stop(&ctx);
    try testing.expectEqual(@as(usize, 1), p_clock.stop_called);
    try testing.expectEqual(@as(usize, 1), p_meter.stop_called);
}

test "lifecycle: partial start failure rolls back already-started" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_clock = TestPlug{};
    var p_meter = TestPlug{ .fail_on_start = true };

    const plugs = [_]PlugHandle{
        .{
            .manifest = mkManifest("clock-system", &[_]Capability{.clock}, &.{}),
            .impl = @ptrCast(&p_clock),
            .vtable = &TestPlug.vtable,
        },
        .{
            .manifest = mkManifest("meter-tokens", &[_]Capability{.meter}, &[_]Dep{.{ .capability = .clock, .kind = .requires }}),
            .impl = @ptrCast(&p_meter),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    try testing.expectError(error.Internal, lc.start(&ctx));

    // clock got started THEN stopped (rollback); meter got one failed
    // start attempt and no stop (never considered started).
    try testing.expectEqual(@as(usize, 1), p_clock.start_called);
    try testing.expectEqual(@as(usize, 1), p_clock.stop_called);
    try testing.expectEqual(@as(usize, 1), p_meter.start_called);
    try testing.expectEqual(@as(usize, 0), p_meter.stop_called);
    try testing.expectEqual(Phase.registered, lc.phase);
}

test "lifecycle: drain timeout on one plug surfaces at end" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_a = TestPlug{};
    var p_b = TestPlug{ .fail_on_drain = true };

    const plugs = [_]PlugHandle{
        .{
            .manifest = mkManifest("a", &[_]Capability{.clock}, &.{}),
            .impl = @ptrCast(&p_a),
            .vtable = &TestPlug.vtable,
        },
        .{
            .manifest = mkManifest("b", &[_]Capability{.meter}, &[_]Dep{.{ .capability = .clock, .kind = .requires }}),
            .impl = @ptrCast(&p_b),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    try lc.start(&ctx);
    try testing.expectError(error.Timeout, lc.drain(&ctx, 1000));

    // Both plugs still got drained despite b's timeout.
    try testing.expectEqual(@as(usize, 1), p_a.drain_called);
    try testing.expectEqual(@as(usize, 1), p_b.drain_called);

    lc.stop(&ctx);
}

test "lifecycle.installSnapshot: handles arbitrary capability counts" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_infra = TestPlug{};

    const plugs = [_]PlugHandle{
        .{
            .manifest = mkManifest("infra-combo", &[_]Capability{ .clock, .meter, .telemetry }, &.{}),
            .impl = @ptrCast(&p_infra),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    try lc.start(&ctx);
    defer lc.stop(&ctx);

    try lc.installSnapshot(reg);

    const snap = reg.acquire();
    defer Registry.release(snap);

    try testing.expectEqual(@as(usize, 1), Registry.sharedFor(snap, .clock).len);
    try testing.expectEqual(@as(usize, 1), Registry.sharedFor(snap, .meter).len);
    try testing.expectEqual(@as(usize, 1), Registry.sharedFor(snap, .telemetry).len);
}

test "lifecycle.installSnapshot: rejects declared vtable version mismatch" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_clock = TestPlug{};
    var manifest = mkManifest("clock-system", &[_]Capability{.clock}, &.{});
    manifest.vtable_version = 999;

    const plugs = [_]PlugHandle{
        .{
            .manifest = manifest,
            .impl = @ptrCast(&p_clock),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    try lc.start(&ctx);
    defer lc.stop(&ctx);

    try testing.expectError(error.VtableVersionMismatch, lc.installSnapshot(reg));
}

test "lifecycle.installSnapshot: rejects duplicate exclusive capability" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var p_clock_a = TestPlug{};
    var p_clock_b = TestPlug{};
    var manifest_a = mkManifest("clock-a", &[_]Capability{.clock}, &.{});
    var manifest_b = mkManifest("clock-b", &[_]Capability{.clock}, &.{});
    manifest_a.slot = .exclusive;
    manifest_b.slot = .exclusive;

    const plugs = [_]PlugHandle{
        .{
            .manifest = manifest_a,
            .impl = @ptrCast(&p_clock_a),
            .vtable = &TestPlug.vtable,
        },
        .{
            .manifest = manifest_b,
            .impl = @ptrCast(&p_clock_b),
            .vtable = &TestPlug.vtable,
        },
    };

    var lc = try Lifecycle.init(testing.allocator, &plugs);
    defer lc.deinit();

    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    try lc.start(&ctx);
    defer lc.stop(&ctx);

    try testing.expectError(error.ExclusiveSlotConflict, lc.installSnapshot(reg));
}
