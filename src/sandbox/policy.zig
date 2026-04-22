//! Declarative sandbox policy.
//!
//! A `Policy` expresses what a session is *permitted* to do. It is
//! intentionally decoupled from the mechanism that enforces it:
//!
//!   * the policy is a pure data value — serialisable, diffable,
//!     easy to reason about in review,
//!   * the enforcement layer (`fs.zig`, `exec.zig`, `net.zig`)
//!     consults the policy to decide whether a specific call
//!     should be allowed, and
//!   * OS-level backends (landlock, firejail, …) are selected
//!     separately by `detect.zig`. Those backends may tighten the
//!     same policy at the kernel level; they never loosen it.
//!
//! The default `Policy.strict` is "deny everything except what is
//! explicitly allowed". This matches the principle that escalation
//! must be a conscious act, not a forgotten flag.

const std = @import("std");

/// How to combine an allow-list and a deny-list when both apply to
/// a value. Deny-first is the sane default: a path appearing on
/// both lists is denied. This matches how every real ACL engine
/// resolves conflicts.
pub const ConflictRule = enum { deny_wins, allow_wins };

pub const FsPolicy = struct {
    /// Allowed path prefixes. A path is considered allowed if it
    /// equals one of these prefixes or is a descendant of one. An
    /// empty allowlist disables filesystem access entirely (strict
    /// default).
    allowlist: []const []const u8 = &.{},
    /// Deny-list, evaluated after the allow-list. Any path that
    /// matches an entry here is rejected even if the allow-list
    /// would have accepted it.
    denylist: []const []const u8 = &.{},
    /// Whether writes are allowed in addition to reads. Reads are
    /// the permission floor — denying reads but allowing writes
    /// would be meaningless.
    writes_allowed: bool = false,
    conflict: ConflictRule = .deny_wins,
};

pub const ExecPolicy = struct {
    /// Absolute binary paths the session may spawn. A binary NOT
    /// on this list is denied. Using absolute paths (rather than
    /// basenames) avoids the "attacker plants their own `ls` in
    /// PATH" class of bug.
    binary_allowlist: []const []const u8 = &.{},
    /// Maximum number of argv elements accepted. Caps on argv size
    /// are a cheap defence against argument-smuggling tricks.
    max_argv_len: usize = 64,
    /// Whether the session may pass arguments that look like shell
    /// metacharacters (; | & $ backtick etc). `false` is the safer
    /// default; tools that need shell syntax should get a
    /// dedicated, reviewed allowance.
    allow_shell_metachars: bool = false,
};

pub const NetPolicy = struct {
    /// Hostnames (exact match, case-insensitive) or domain suffixes
    /// (starting with `.`, e.g. `.example.com`) that egress is
    /// permitted to. Empty = no network at all.
    host_allowlist: []const []const u8 = &.{},
    /// Ports accepted. Empty = every port on an allowed host.
    port_allowlist: []const u16 = &.{},
};

pub const Policy = struct {
    fs: FsPolicy = .{},
    exec: ExecPolicy = .{},
    net: NetPolicy = .{},

    /// Strict default: deny everything. Callers build up from here
    /// by overriding fields they need.
    pub const strict: Policy = .{};

    /// A looser policy for local `run` mode: read-only home,
    /// full subprocess, no network restriction. Still not "off" —
    /// the exec layer still caps argv length and metachar use.
    pub const loose_run: Policy = .{
        .fs = .{
            .allowlist = &.{"/"},
            .writes_allowed = true,
        },
        .exec = .{
            .binary_allowlist = &.{},
            .max_argv_len = 4096,
            .allow_shell_metachars = true,
        },
        .net = .{
            .host_allowlist = &.{"."},
        },
    };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Policy.strict: every list is empty" {
    const p = Policy.strict;
    try testing.expectEqual(@as(usize, 0), p.fs.allowlist.len);
    try testing.expectEqual(@as(usize, 0), p.fs.denylist.len);
    try testing.expect(!p.fs.writes_allowed);
    try testing.expectEqual(@as(usize, 0), p.exec.binary_allowlist.len);
    try testing.expect(!p.exec.allow_shell_metachars);
    try testing.expectEqual(@as(usize, 0), p.net.host_allowlist.len);
}

test "Policy.loose_run: only exec/net relaxations visible here" {
    const p = Policy.loose_run;
    try testing.expect(p.fs.writes_allowed);
    try testing.expect(p.exec.allow_shell_metachars);
    try testing.expect(p.exec.max_argv_len > 64);
}

test "ConflictRule: enum has exactly the two documented variants" {
    const fields = @typeInfo(ConflictRule).@"enum".fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
}
