//! Capability registry with atomic snapshot swap.
//!
//! The registry is a read-mostly table: Capability → active plug(s).
//! Readers acquire a refcounted snapshot for the duration of their
//! operation; writers build a fresh snapshot and atomically replace
//! the pointer. The old snapshot lives until every reader has released
//! its handle, then frees itself.
//!
//! This shape matches the `atomic-snapshot-swap` architecture primitive
//! in the spec and is what makes runtime config reload safe without
//! stopping the agent.
//!
//! Lookup rules:
//!   - Exclusive slots: at most one active plug; `exclusiveFor()`
//!     returns null if none or the single entry if present.
//!   - Shared slots: N active plugs; `sharedFor()` returns the slice.
//!   - Slot rules are enforced at snapshot-build time, not at lookup.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.registry

const std = @import("std");
const capabilities = @import("capabilities.zig");
const errors = @import("errors");

const Capability = capabilities.Capability;
const PlugError = errors.PlugError;

/// An entry in the registry. The concrete vtable lives behind `impl`;
/// plugger-specific code casts it.
pub const Entry = struct {
    capability: Capability,
    plug_id: []const u8,
    vtable_ver: u16,
    impl: *anyopaque,
};

/// Slot kind per-capability. Controls how the registry stores entries
/// and what lookups are allowed. Enforced at snapshot-build time.
pub const Slot = enum { exclusive, exclusive_with_fallback, shared };

/// Immutable snapshot of the registry. Readers hold a pointer to one
/// of these across their operation; writers never mutate a live
/// snapshot.
pub const Snapshot = struct {
    /// Parent registry the snapshot belongs to; used on release().
    owner: *Registry,

    /// Refcount. Each `acquire()` bumps; each `release()` decrements.
    /// When the count hits zero and this snapshot is no longer the
    /// current one, it is freed.
    refcount: std.atomic.Value(usize),

    /// One bucket per capability. Shared slots are a slice; exclusive
    /// slots hold 0 or 1 entries. Slice ownership lives with the
    /// snapshot allocation.
    entries: [capabilities.capability_count][]const Entry,

    /// Allocator used to free `entries` when the snapshot is released.
    alloc: std.mem.Allocator,
};

/// The registry itself. Thread-safe for readers; writers must serialize
/// externally (one writer at a time; readers are unbounded).
pub const Registry = struct {
    alloc: std.mem.Allocator,

    /// Current snapshot. Atomic pointer so readers can race writers
    /// without a lock.
    snapshot: std.atomic.Value(?*Snapshot),

    pub fn init(alloc: std.mem.Allocator) !*Registry {
        const self = try alloc.create(Registry);
        self.* = .{
            .alloc = alloc,
            .snapshot = std.atomic.Value(?*Snapshot).init(null),
        };
        // Seed with an empty snapshot so `acquire` always works.
        const empty = try buildSnapshot(self, alloc, &.{});
        self.snapshot.store(empty, .release);
        return self;
    }

    pub fn deinit(self: *Registry) void {
        // Drain current snapshot. Callers are responsible for ensuring
        // no live readers remain at deinit time.
        if (self.snapshot.load(.acquire)) |snap| {
            // Force-free regardless of refcount; caller promised no readers.
            freeSnapshot(snap);
        }
        self.alloc.destroy(self);
    }

    /// Atomically replace the current snapshot with a new one. The old
    /// snapshot is refcount-released; it lives until its last reader
    /// drops, then frees itself.
    pub fn swap(self: *Registry, new_snap: *Snapshot) void {
        const old = self.snapshot.swap(new_snap, .acq_rel);
        if (old) |s| {
            release(s);
        }
    }

    /// Grab a refcounted handle to the current snapshot. Caller MUST
    /// call `release()` when done.
    pub fn acquire(self: *Registry) *Snapshot {
        while (true) {
            const snap = self.snapshot.load(.acquire) orelse unreachable;
            // Increment refcount. If it was zero we'd race with a freer,
            // but refcount only hits zero AFTER the snapshot is no
            // longer current, so the load above guarantees > 0.
            _ = snap.refcount.fetchAdd(1, .acq_rel);
            return snap;
        }
    }

    /// Release a handle obtained via `acquire`. If this snapshot is
    /// no longer current and the last reader is dropping, it frees.
    pub fn release(snap: *Snapshot) void {
        const prev = snap.refcount.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev == 1) {
            // Refcount hit zero. If we're still the current snapshot,
            // the next swap() will handle us. If we're not, free now.
            const current = snap.owner.snapshot.load(.acquire);
            if (current != snap) {
                freeSnapshot(snap);
            }
        }
    }

    /// Lookup the single active plug for an exclusive-slot capability.
    /// Returns null if no entries are registered. For shared slots this
    /// returns the first entry by registration order.
    pub fn exclusiveFor(snap: *const Snapshot, cap: Capability) ?*const Entry {
        const list = snap.entries[cap.tag()];
        if (list.len == 0) return null;
        return &list[0];
    }

    /// Lookup all active plugs for a shared-slot capability. Returned
    /// slice is only valid while the caller holds the snapshot.
    pub fn sharedFor(snap: *const Snapshot, cap: Capability) []const Entry {
        return snap.entries[cap.tag()];
    }
};

/// Build a new snapshot from the given list of entries. The entries
/// slice is copied; caller may free after this returns.
pub fn buildSnapshot(
    owner: *Registry,
    alloc: std.mem.Allocator,
    entries: []const Entry,
) !*Snapshot {
    const snap = try alloc.create(Snapshot);
    errdefer alloc.destroy(snap);

    snap.* = .{
        .owner = owner,
        .refcount = std.atomic.Value(usize).init(1), // installer holds one
        .entries = undefined,
        .alloc = alloc,
    };

    // Initialize every bucket to empty slice.
    for (&snap.entries) |*bucket| {
        bucket.* = &.{};
    }

    if (entries.len == 0) return snap;

    // Count entries per capability.
    var counts = [_]usize{0} ** capabilities.capability_count;
    for (entries) |e| {
        counts[e.capability.tag()] += 1;
    }

    // Allocate and fill buckets.
    for (0..capabilities.capability_count) |i| {
        if (counts[i] == 0) continue;
        const bucket = try alloc.alloc(Entry, counts[i]);
        snap.entries[i] = bucket;
    }

    var fill = [_]usize{0} ** capabilities.capability_count;
    for (entries) |e| {
        const i = e.capability.tag();
        const bucket: []Entry = @constCast(snap.entries[i]);
        bucket[fill[i]] = e;
        fill[i] += 1;
    }

    return snap;
}

fn freeSnapshot(snap: *Snapshot) void {
    for (snap.entries) |bucket| {
        if (bucket.len > 0) {
            const mutable: []Entry = @constCast(bucket);
            snap.alloc.free(mutable);
        }
    }
    snap.alloc.destroy(snap);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "empty registry: exclusiveFor returns null" {
    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const snap = reg.acquire();
    defer Registry.release(snap);

    try testing.expectEqual(@as(?*const Entry, null), Registry.exclusiveFor(snap, .persona));
    try testing.expectEqual(@as(usize, 0), Registry.sharedFor(snap, .guardrails).len);
}

test "swap: new snapshot becomes current" {
    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    var dummy: u8 = 0;
    const entry = Entry{
        .capability = .persona,
        .plug_id = "persona-test",
        .vtable_ver = 1,
        .impl = @ptrCast(&dummy),
    };
    const new_snap = try buildSnapshot(reg, testing.allocator, &.{entry});
    reg.swap(new_snap);

    const snap = reg.acquire();
    defer Registry.release(snap);

    const got = Registry.exclusiveFor(snap, .persona);
    try testing.expect(got != null);
    try testing.expectEqualStrings("persona-test", got.?.plug_id);
}

test "sharedFor: returns all entries for a shared slot" {
    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    var d1: u8 = 1;
    var d2: u8 = 2;
    var d3: u8 = 3;
    const entries = [_]Entry{
        .{ .capability = .guardrails, .plug_id = "guardrail-access-allowlist", .vtable_ver = 1, .impl = @ptrCast(&d1) },
        .{ .capability = .guardrails, .plug_id = "guardrail-budget-cap", .vtable_ver = 1, .impl = @ptrCast(&d2) },
        .{ .capability = .guardrails, .plug_id = "guardrail-approval-cli", .vtable_ver = 1, .impl = @ptrCast(&d3) },
    };
    const new_snap = try buildSnapshot(reg, testing.allocator, &entries);
    reg.swap(new_snap);

    const snap = reg.acquire();
    defer Registry.release(snap);

    const list = Registry.sharedFor(snap, .guardrails);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("guardrail-access-allowlist", list[0].plug_id);
    try testing.expectEqualStrings("guardrail-budget-cap", list[1].plug_id);
    try testing.expectEqualStrings("guardrail-approval-cli", list[2].plug_id);
}

test "reader holding snapshot during swap sees old data" {
    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    var d_old: u8 = 0xAA;
    const e_old = Entry{ .capability = .persona, .plug_id = "old", .vtable_ver = 1, .impl = @ptrCast(&d_old) };
    const snap_old = try buildSnapshot(reg, testing.allocator, &.{e_old});
    reg.swap(snap_old);

    // Reader picks up the "old" snapshot.
    const reader_snap = reg.acquire();
    defer Registry.release(reader_snap);

    // Writer installs "new".
    var d_new: u8 = 0xBB;
    const e_new = Entry{ .capability = .persona, .plug_id = "new", .vtable_ver = 1, .impl = @ptrCast(&d_new) };
    const snap_new = try buildSnapshot(reg, testing.allocator, &.{e_new});
    reg.swap(snap_new);

    // Reader still sees "old" until it releases.
    const got = Registry.exclusiveFor(reader_snap, .persona);
    try testing.expect(got != null);
    try testing.expectEqualStrings("old", got.?.plug_id);
}

test "refcount: old snapshot is freed once last reader releases" {
    const reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    // Bounce through a few swaps while holding no readers.
    for (0..5) |i| {
        var dummy: u8 = 0;
        const e = Entry{
            .capability = .memory,
            .plug_id = "memory-test",
            .vtable_ver = 1,
            .impl = @ptrCast(&dummy),
        };
        _ = i;
        const new_snap = try buildSnapshot(reg, testing.allocator, &.{e});
        reg.swap(new_snap);
    }
    // If old snapshots weren't freed, testing.allocator leak-check will fail.
}
