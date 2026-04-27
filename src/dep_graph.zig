//! Dependency graph + topological sort over manifests.
//!
//! Given a set of Manifests, produce a start order such that every
//! plug's `requires` edges point at capabilities already provided by
//! earlier plugs in the order. Conflicts are detected; cycles are
//! detected; missing requirements are detected.
//!
//! Scope boundary: this module does NOT know about the Registry — it
//! operates on Manifest metadata alone. Lifecycle consults it to
//! decide register/start order.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.dependency-graph

const std = @import("std");
const capabilities = @import("capabilities.zig");
const manifest_mod = @import("manifest.zig");
const errors = @import("errors");

const Capability = capabilities.Capability;
const Manifest = manifest_mod.Manifest;
const PlugError = errors.PlugError;

pub const SortError = error{
    CycleDetected,
    MissingCapability,
    ConflictingPlugs,
} || std.mem.Allocator.Error;

/// Diagnostic describing a topo-sort failure. Callers can render this
/// to a human-readable log; plugs can't recover from it.
pub const Failure = union(enum) {
    cycle: []const u8, // plug id
    missing: struct { plug: []const u8, cap: Capability },
    conflict: struct { a: []const u8, b: []const u8, cap: Capability },
};

/// Topological sort. Returns a slice of manifest indices in start
/// order. Caller owns the returned slice and must free it with `alloc`.
pub fn topoSort(
    alloc: std.mem.Allocator,
    manifests: []const Manifest,
) SortError![]const usize {
    // Build "capability is provided by at least one manifest" map.
    var provided = [_]bool{false} ** capabilities.capability_count;
    for (manifests) |m| {
        for (m.provides) |cap| {
            provided[cap.tag()] = true;
        }
    }

    // Check every `requires` edge against the provided map.
    for (manifests) |m| {
        for (m.deps) |d| {
            if (d.kind == .requires and !provided[d.capability.tag()]) {
                return SortError.MissingCapability;
            }
        }
    }

    // Detect conflicts: if two manifests each provide capability X and
    // either declares `conflicts` against X, that's a conflict.
    for (manifests, 0..) |m, i| {
        for (m.deps) |d| {
            if (d.kind != .conflicts) continue;
            // For each other manifest providing this capability, fail.
            for (manifests, 0..) |n, j| {
                if (i == j) continue;
                for (n.provides) |cap| {
                    if (cap == d.capability) return SortError.ConflictingPlugs;
                }
            }
        }
    }

    // Build in-degree: for each manifest, count how many `requires`
    // edges it has pointing at capabilities provided by OTHER
    // manifests (self-provisioned requirements don't block start).
    const n = manifests.len;
    if (n == 0) return &.{};

    const in_deg = try alloc.alloc(usize, n);
    errdefer alloc.free(in_deg);

    for (in_deg) |*v| v.* = 0;

    for (manifests, 0..) |m, i| {
        for (m.deps) |d| {
            if (d.kind != .requires) continue;
            // Does this manifest provide the capability itself?
            var self_satisfied = false;
            for (m.provides) |c| {
                if (c == d.capability) {
                    self_satisfied = true;
                    break;
                }
            }
            if (self_satisfied) continue;
            in_deg[i] += 1;
        }
    }

    // Kahn's algorithm. Ties broken by (start_order asc, id asc).
    const order = try alloc.alloc(usize, n);
    errdefer alloc.free(order);
    var placed: usize = 0;

    var remaining = try alloc.alloc(bool, n);
    defer alloc.free(remaining);
    for (remaining) |*v| v.* = true;

    while (placed < n) {
        // Find ready candidates: in_deg == 0 and still remaining.
        var best: ?usize = null;
        for (manifests, 0..) |m, i| {
            if (!remaining[i]) continue;
            if (in_deg[i] != 0) continue;
            if (best) |b| {
                const best_m = manifests[b];
                if (m.start_order < best_m.start_order) {
                    best = i;
                } else if (m.start_order == best_m.start_order and std.mem.lessThan(u8, m.id, best_m.id)) {
                    best = i;
                }
            } else {
                best = i;
            }
        }

        if (best == null) {
            // No progress possible → cycle. `order` gets freed by the
            // errdefer above; don't double-free here.
            return SortError.CycleDetected;
        }

        const chosen = best.?;
        order[placed] = chosen;
        placed += 1;
        remaining[chosen] = false;

        // Decrement in-degree of everyone who required capabilities
        // this plug provides.
        const m = manifests[chosen];
        for (m.provides) |cap| {
            for (manifests, 0..) |other, j| {
                if (!remaining[j]) continue;
                for (other.deps) |d| {
                    if (d.kind != .requires) continue;
                    if (d.capability != cap) continue;
                    // Don't double-count self-satisfied.
                    var self = false;
                    for (other.provides) |c| {
                        if (c == cap) {
                            self = true;
                            break;
                        }
                    }
                    if (self) continue;
                    if (in_deg[j] > 0) in_deg[j] -= 1;
                }
            }
        }
    }

    alloc.free(in_deg);
    return order;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Slot = @import("registry.zig").Slot;
const Dep = manifest_mod.Dep;

fn mk(id: []const u8, provides: []const Capability, deps: []const Dep, start_order: i32) Manifest {
    return .{
        .id = id,
        .version = "2026.04.23",
        .provides = provides,
        .deps = deps,
        .slot = .shared,
        .start_order = start_order,
    };
}

test "empty input: returns empty order" {
    const order = try topoSort(testing.allocator, &.{});
    defer if (order.len > 0) testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 0), order.len);
}

test "single manifest: returns single-element order" {
    const manifests = [_]Manifest{mk("clock-system", &[_]Capability{.clock}, &.{}, 0)};
    const order = try topoSort(testing.allocator, &manifests);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order.len);
    try testing.expectEqual(@as(usize, 0), order[0]);
}

test "chain: B requires A → A starts before B" {
    const manifests = [_]Manifest{
        mk("b-depends-on-clock", &[_]Capability{.memory}, &[_]Dep{.{ .capability = .clock, .kind = .requires }}, 0),
        mk("a-provides-clock", &[_]Capability{.clock}, &.{}, 0),
    };
    const order = try topoSort(testing.allocator, &manifests);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 2), order.len);
    // a (index 1) comes before b (index 0)
    try testing.expectEqual(@as(usize, 1), order[0]);
    try testing.expectEqual(@as(usize, 0), order[1]);
}

test "cycle: mutual requires → CycleDetected" {
    const manifests = [_]Manifest{
        mk("a", &[_]Capability{.memory}, &[_]Dep{.{ .capability = .clock, .kind = .requires }}, 0),
        mk("b", &[_]Capability{.clock}, &[_]Dep{.{ .capability = .memory, .kind = .requires }}, 0),
    };
    try testing.expectError(SortError.CycleDetected, topoSort(testing.allocator, &manifests));
}

test "missing capability: MissingCapability" {
    const manifests = [_]Manifest{
        mk("needs-persona", &[_]Capability{.memory}, &[_]Dep{.{ .capability = .persona, .kind = .requires }}, 0),
    };
    try testing.expectError(SortError.MissingCapability, topoSort(testing.allocator, &manifests));
}

test "conflict: two plugs, one declares conflict → ConflictingPlugs" {
    const manifests = [_]Manifest{
        mk("provider-a", &[_]Capability{.providers}, &[_]Dep{.{ .capability = .providers, .kind = .conflicts }}, 0),
        mk("provider-b", &[_]Capability{.providers}, &.{}, 0),
    };
    try testing.expectError(SortError.ConflictingPlugs, topoSort(testing.allocator, &manifests));
}

test "tie-break: lower start_order first, then id alphabetical" {
    const manifests = [_]Manifest{
        mk("zzz-plug", &[_]Capability{.memory}, &.{}, 5),
        mk("aaa-plug", &[_]Capability{.clock}, &.{}, 5),
        mk("first", &[_]Capability{.telemetry}, &.{}, 1),
    };
    const order = try topoSort(testing.allocator, &manifests);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 3), order.len);
    // start_order=1 wins first
    try testing.expectEqual(@as(usize, 2), order[0]); // "first"
    // then ties on start_order=5: aaa-plug before zzz-plug
    try testing.expectEqual(@as(usize, 1), order[1]); // "aaa-plug"
    try testing.expectEqual(@as(usize, 0), order[2]); // "zzz-plug"
}

test "self-satisfaction: plug providing what it requires is fine" {
    const manifests = [_]Manifest{
        mk("self-referential", &[_]Capability{.memory}, &[_]Dep{.{ .capability = .memory, .kind = .requires }}, 0),
    };
    const order = try topoSort(testing.allocator, &manifests);
    defer testing.allocator.free(order);

    try testing.expectEqual(@as(usize, 1), order.len);
}
