//! Integration tests for sandbox exec checks.
//!
//! Assertions here cover the surface the runtime relies on before
//! ever spawning a subprocess: the binary allowlist, argv caps,
//! and the shell-metachar screen with and without the opt-in.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const exec_mod = tigerclaw.sandbox.exec;
const policy_mod = tigerclaw.sandbox.policy;

test "sandbox exec: strict default denies any binary" {
    try testing.expectEqual(
        exec_mod.Rejection.binary_not_allowlisted,
        exec_mod.check(.{}, &.{"/bin/ls"}),
    );
}

test "sandbox exec: empty argv is rejected explicitly" {
    try testing.expectEqual(exec_mod.Rejection.argv_empty, exec_mod.check(.{}, &.{}));
}

test "sandbox exec: allowlisted binary with safe args passes" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{ "/bin/ls", "/usr/bin/git" } };
    try testing.expectEqual(exec_mod.Rejection.none, exec_mod.check(p, &.{ "/bin/ls", "-la" }));
    try testing.expectEqual(exec_mod.Rejection.none, exec_mod.check(p, &.{ "/usr/bin/git", "status" }));
}

test "sandbox exec: different basename with same suffix is not confused" {
    // The allowlist is exact-path; `/mybin/ls` must not pass when
    // only `/bin/ls` was allowed.
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/ls"} };
    try testing.expectEqual(
        exec_mod.Rejection.binary_not_allowlisted,
        exec_mod.check(p, &.{"/mybin/ls"}),
    );
}

test "sandbox exec: argv_too_long protects against smuggling" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/ls"}, .max_argv_len = 3 };
    try testing.expectEqual(
        exec_mod.Rejection.argv_too_long,
        exec_mod.check(p, &.{ "/bin/ls", "a", "b", "c" }),
    );
}

test "sandbox exec: shell metachars denied by default" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/sh"} };
    try testing.expectEqual(
        exec_mod.Rejection.shell_metachar_rejected,
        exec_mod.check(p, &.{ "/bin/sh", "-c", "rm -rf / ; echo done" }),
    );
    try testing.expectEqual(
        exec_mod.Rejection.shell_metachar_rejected,
        exec_mod.check(p, &.{ "/bin/sh", "echo `id`" }),
    );
}

test "sandbox exec: NUL byte inside argv is rejected" {
    const p = policy_mod.ExecPolicy{ .binary_allowlist = &.{"/bin/ls"} };
    const bad = [_]u8{ 'a', 0, 'b' };
    try testing.expectEqual(
        exec_mod.Rejection.shell_metachar_rejected,
        exec_mod.check(p, &.{ "/bin/ls", &bad }),
    );
}

test "sandbox exec: opt-in allows quoted shell commands" {
    const p = policy_mod.ExecPolicy{
        .binary_allowlist = &.{"/bin/sh"},
        .allow_shell_metachars = true,
    };
    try testing.expectEqual(
        exec_mod.Rejection.none,
        exec_mod.check(p, &.{ "/bin/sh", "-c", "a && b | c" }),
    );
}
