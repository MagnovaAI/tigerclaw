//! Backend detection.
//!
//! Selects an OS-level sandbox backend from the preference order,
//! falling back to `.noop` when nothing better is available. For
//! this first landing we ship only the `.noop` backend implementing
//! the `Sandbox` vtable; Linux backends (landlock, firejail,
//! bubblewrap) and Docker will slot in later behind this same
//! interface.
//!
//! Selection priority (auto):
//!
//!   Linux:   landlock > firejail > bubblewrap > docker > noop
//!   macOS:   docker > noop
//!   other:   noop
//!
//! Until each backend lands, `available(...)` returns `false`
//! for it and `select(.auto, …)` collapses to `.noop`.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

pub const Backend = enum {
    /// Let detect pick the best backend for the current host.
    auto,
    /// No OS-level isolation; application-layer policy only.
    noop,
    /// Linux kernel LSM (not yet implemented — fails over to noop).
    landlock,
    /// Linux firejail wrapper (not yet implemented).
    firejail,
    /// Linux bubblewrap wrapper (not yet implemented).
    bubblewrap,
    /// Cross-platform Docker isolation (not yet implemented).
    docker,
};

/// Report availability for each backend on the current host.
/// Backends not yet implemented report `false` unconditionally so
/// `auto` cannot accidentally resolve to a stub.
pub fn available(backend: Backend) bool {
    return switch (backend) {
        .auto => false, // `.auto` is a preference, not a backend
        .noop => true,
        .landlock, .firejail, .bubblewrap => false, // land later
        .docker => false, // lands later
    };
}

/// Pick a backend. Always returns a backend that is `available`
/// at call time; callers do not need to retry on failure.
pub fn select(preference: Backend) Backend {
    if (preference != .auto and available(preference)) return preference;
    if (preference != .auto) return .noop;

    // `.auto`: walk the host-specific priority list.
    const ordered: []const Backend = comptime switch (builtin.os.tag) {
        .linux => &.{ .landlock, .firejail, .bubblewrap, .docker, .noop },
        .macos => &.{ .docker, .noop },
        else => &.{.noop},
    };
    for (ordered) |b| if (available(b)) return b;
    return .noop;
}

/// Construct a Sandbox handle for the selected backend. Today
/// every non-noop backend falls back to noop; this keeps the
/// call-site stable as real backends land.
pub fn open(storage: *root.Storage, preference: Backend) root.Sandbox {
    const chosen = select(preference);
    return switch (chosen) {
        .noop => blk: {
            storage.noop = .{};
            break :blk storage.noop.sandbox();
        },
        else => blk: {
            // Future backends add their own storage slot + branch.
            storage.noop = .{};
            break :blk storage.noop.sandbox();
        },
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "available: noop is always available" {
    try testing.expect(available(.noop));
}

test "available: unimplemented backends report false" {
    try testing.expect(!available(.landlock));
    try testing.expect(!available(.firejail));
    try testing.expect(!available(.bubblewrap));
    try testing.expect(!available(.docker));
}

test "select: auto falls through to noop" {
    try testing.expectEqual(Backend.noop, select(.auto));
}

test "select: explicit preference falls back to noop when unavailable" {
    try testing.expectEqual(Backend.noop, select(.docker));
    try testing.expectEqual(Backend.noop, select(.landlock));
}

test "open: returns a noop sandbox today" {
    var storage: root.Storage = .{};
    const sb = open(&storage, .auto);
    try testing.expectEqualStrings("noop", sb.name());
    try testing.expect(sb.isAvailable());
}
