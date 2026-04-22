//! Filesystem access check.
//!
//! Given an `FsPolicy`, decide whether a given absolute path may be
//! opened for reading or writing. The check is policy-only — it
//! does not touch the filesystem, spawn anything, or allocate. That
//! keeps it safe to call from any context, including inside error
//! paths and panic handlers.
//!
//! Matching rules:
//!   * An allowlist entry matches a path if the path equals it or
//!     is a descendant of it (prefix match at a directory boundary).
//!   * A denylist entry matches the same way.
//!   * `deny_wins` (default): deny matches short-circuit allows.
//!   * `allow_wins`: used for overrides — an allow match wins even
//!     if a deny match applies. Rarely the right answer; present
//!     for completeness.

const std = @import("std");
const policy_mod = @import("policy.zig");

pub const Access = enum { read, write };

pub const Decision = enum { allow, deny };

/// Normalise one edge case: treat `""` as not-a-match. Beyond that
/// we keep the prefix semantics byte-literal — callers are
/// responsible for canonicalising paths before handing them in
/// (resolving `..`, symlinks, etc.). Policy checks run against a
/// *logical* path as declared by the caller; that logical view is
/// what ends up in audit logs, so it must not be silently
/// rewritten here.
pub fn matchesPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (std.mem.eql(u8, path, prefix)) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    // `prefix` == "/" is a special case: "/anything" starts with "/"
    // AND the character right after the prefix is "a" (part of the
    // path). Normally we require a '/' boundary; a single-byte "/"
    // prefix means the prefix already ends in a separator, so any
    // extension is valid.
    if (prefix.len == 1 and prefix[0] == '/') return true;
    if (prefix[prefix.len - 1] == '/') return true;
    return path.len > prefix.len and path[prefix.len] == '/';
}

pub fn check(
    fs_policy: policy_mod.FsPolicy,
    path: []const u8,
    access: Access,
) Decision {
    if (access == .write and !fs_policy.writes_allowed) return .deny;

    var allow_hit = false;
    for (fs_policy.allowlist) |entry| {
        if (matchesPrefix(path, entry)) {
            allow_hit = true;
            break;
        }
    }

    var deny_hit = false;
    for (fs_policy.denylist) |entry| {
        if (matchesPrefix(path, entry)) {
            deny_hit = true;
            break;
        }
    }

    return switch (fs_policy.conflict) {
        .deny_wins => if (deny_hit or !allow_hit) .deny else .allow,
        .allow_wins => if (allow_hit) .allow else .deny,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "matchesPrefix: exact and directory-boundary matches" {
    try testing.expect(matchesPrefix("/home/alice", "/home/alice"));
    try testing.expect(matchesPrefix("/home/alice/.zshrc", "/home/alice"));
    try testing.expect(!matchesPrefix("/home/alicebob/x", "/home/alice"));
    try testing.expect(matchesPrefix("/tmp/x", "/"));
    try testing.expect(!matchesPrefix("/home/alice", ""));
}

test "matchesPrefix: prefix with trailing slash is respected" {
    try testing.expect(matchesPrefix("/home/alice/x", "/home/alice/"));
    try testing.expect(!matchesPrefix("/home/alicebob/x", "/home/alice/"));
}

test "check: strict policy denies everything" {
    try testing.expectEqual(Decision.deny, check(.{}, "/etc/passwd", .read));
    try testing.expectEqual(Decision.deny, check(.{}, "/home/alice", .read));
}

test "check: allowlist grants read access" {
    const p = policy_mod.FsPolicy{ .allowlist = &.{"/home/alice"} };
    try testing.expectEqual(Decision.allow, check(p, "/home/alice/file", .read));
    try testing.expectEqual(Decision.deny, check(p, "/etc/passwd", .read));
}

test "check: writes require writes_allowed" {
    const ro = policy_mod.FsPolicy{ .allowlist = &.{"/work"} };
    try testing.expectEqual(Decision.allow, check(ro, "/work/x", .read));
    try testing.expectEqual(Decision.deny, check(ro, "/work/x", .write));

    const rw = policy_mod.FsPolicy{ .allowlist = &.{"/work"}, .writes_allowed = true };
    try testing.expectEqual(Decision.allow, check(rw, "/work/x", .write));
}

test "check: deny_wins short-circuits even matching allows" {
    const p = policy_mod.FsPolicy{
        .allowlist = &.{"/home"},
        .denylist = &.{"/home/secrets"},
        .writes_allowed = true,
    };
    try testing.expectEqual(Decision.allow, check(p, "/home/alice/x", .read));
    try testing.expectEqual(Decision.deny, check(p, "/home/secrets/k", .read));
    try testing.expectEqual(Decision.deny, check(p, "/home/secrets/k", .write));
}

test "check: allow_wins flips the tie-breaker" {
    const p = policy_mod.FsPolicy{
        .allowlist = &.{"/home/alice/exception"},
        .denylist = &.{"/home/alice"},
        .conflict = .allow_wins,
    };
    try testing.expectEqual(Decision.allow, check(p, "/home/alice/exception/x", .read));
    try testing.expectEqual(Decision.deny, check(p, "/home/alice/other", .read));
}
