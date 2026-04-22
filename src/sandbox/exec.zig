//! Subprocess-execution check.
//!
//! Decides whether a given `argv` is allowed to be spawned under
//! the session's `ExecPolicy`. Like `fs.zig`, this is a pure
//! function — it neither spawns nor touches the filesystem.
//!
//! Three independent guards apply:
//!
//!   1. Binary must be on the allowlist, by exact absolute path.
//!   2. `argv.len` must not exceed `max_argv_len`.
//!   3. If `allow_shell_metachars` is false, no argument may
//!      contain any shell-metacharacter byte. We reject at the
//!      byte level rather than trying to parse shell grammar:
//!      parsing shell is a losing game, but *refusing* anything
//!      that could be interpreted as shell syntax is tractable.
//!
//! The denial kind is surfaced in `Rejection` so callers can log
//! a precise reason and so tests can distinguish "wrong binary"
//! from "argv too long" without string matching.

const std = @import("std");
const policy_mod = @import("policy.zig");

pub const Rejection = enum {
    none,
    binary_not_allowlisted,
    argv_too_long,
    argv_empty,
    shell_metachar_rejected,
};

/// The set of bytes treated as shell metacharacters. Conservative
/// by design — we deny everything that could chain, redirect,
/// expand, or interpret another command. `\0` is rejected
/// separately below because it terminates strings on every Unix
/// syscall and should never appear inside an argv element anyway.
const shell_metachars: []const u8 = &[_]u8{
    ';', '|',  '&',  '$', '`', '\n', '\r',
    '>', '<',  '(',  ')', '{', '}',  '*',
    '?', '\\', '\'', '"',
};

pub fn containsShellMetachar(arg: []const u8) bool {
    for (arg) |c| {
        if (c == 0) return true;
        for (shell_metachars) |m| {
            if (c == m) return true;
        }
    }
    return false;
}

pub fn check(
    exec_policy: policy_mod.ExecPolicy,
    argv: []const []const u8,
) Rejection {
    if (argv.len == 0) return .argv_empty;
    if (argv.len > exec_policy.max_argv_len) return .argv_too_long;

    var binary_ok = false;
    for (exec_policy.binary_allowlist) |allowed| {
        if (std.mem.eql(u8, argv[0], allowed)) {
            binary_ok = true;
            break;
        }
    }
    if (!binary_ok) return .binary_not_allowlisted;

    if (!exec_policy.allow_shell_metachars) {
        // argv[0] is the binary — its path is already validated by
        // the allowlist, but we still scan it so a policy with an
        // entry like "/bin/sh;rm -rf /" cannot sneak in via a
        // loosely-constructed allowlist.
        for (argv) |a| if (containsShellMetachar(a)) return .shell_metachar_rejected;
    }

    return .none;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "check: empty argv is rejected" {
    try testing.expectEqual(Rejection.argv_empty, check(.{}, &.{}));
}

test "check: strict default denies any binary" {
    try testing.expectEqual(Rejection.binary_not_allowlisted, check(.{}, &.{"/bin/ls"}));
}

test "check: allowlisted binary with safe args passes" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/ls"} };
    try testing.expectEqual(Rejection.none, check(p, &.{ "/bin/ls", "-la", "/tmp" }));
}

test "check: argv_too_long caps argv size" {
    const p = policy_mod.ExecPolicy{
        .binary_allowlist = &.{"/bin/ls"},
        .max_argv_len = 2,
    };
    try testing.expectEqual(Rejection.argv_too_long, check(p, &.{ "/bin/ls", "-a", "extra" }));
}

test "check: shell metachar rejected when not allowed" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/sh"} };
    try testing.expectEqual(
        Rejection.shell_metachar_rejected,
        check(p, &.{ "/bin/sh", "rm -rf /; echo oops" }),
    );
    try testing.expectEqual(
        Rejection.shell_metachar_rejected,
        check(p, &.{ "/bin/sh", "a && b" }),
    );
}

test "check: null byte in arg is rejected as shell_metachar" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/ls"} };
    const arg_with_null = [_]u8{ 'a', 0, 'b' };
    try testing.expectEqual(
        Rejection.shell_metachar_rejected,
        check(p, &.{ "/bin/ls", &arg_with_null }),
    );
}

test "check: metachars allowed when policy opts in" {
    const p = policy_mod.ExecPolicy{
        .binary_allowlist = &.{"/bin/sh"},
        .allow_shell_metachars = true,
    };
    try testing.expectEqual(Rejection.none, check(p, &.{ "/bin/sh", "-c", "a | b" }));
}

test "containsShellMetachar: samples" {
    try testing.expect(!containsShellMetachar("hello world"));
    try testing.expect(!containsShellMetachar("/usr/local/bin/foo-bar"));
    try testing.expect(containsShellMetachar("a;b"));
    try testing.expect(containsShellMetachar("$PATH"));
    try testing.expect(containsShellMetachar("`ls`"));
}
