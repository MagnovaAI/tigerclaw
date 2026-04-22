//! Integration tests for sandbox filesystem checks.
//!
//! These defend the decision contract the runtime will build on:
//! strict default denies; writes need `writes_allowed`; denylist
//! wins by default; `allow_wins` is opt-in; prefix match respects
//! directory boundaries.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const fs_mod = tigerclaw.sandbox.fs;
const policy_mod = tigerclaw.sandbox.policy;

test "sandbox fs: empty policy denies all access" {
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(.{}, "/home/alice/.zshrc", .read));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(.{}, "/tmp/out", .write));
}

test "sandbox fs: scoped workspace — reads yes, writes gated" {
    const ro = policy_mod.FsPolicy{ .allowlist = &.{"/workspace"} };
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(ro, "/workspace/main.zig", .read));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(ro, "/workspace/main.zig", .write));

    const rw = policy_mod.FsPolicy{ .allowlist = &.{"/workspace"}, .writes_allowed = true };
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(rw, "/workspace/main.zig", .write));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(rw, "/etc/passwd", .read));
}

test "sandbox fs: deny beats allow for secret subtrees" {
    const p = policy_mod.FsPolicy{
        .allowlist = &.{"/home/alice"},
        .denylist = &.{"/home/alice/.ssh"},
        .writes_allowed = true,
    };
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(p, "/home/alice/code", .read));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(p, "/home/alice/.ssh/id_rsa", .read));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(p, "/home/alice/.ssh/id_rsa", .write));
}

test "sandbox fs: directory boundary prevents prefix confusion" {
    const p = policy_mod.FsPolicy{ .allowlist = &.{"/home/alice"} };
    // `/home/alicebob/...` must NOT be accepted just because it
    // literally starts with `/home/alice`.
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(p, "/home/alicebob/x", .read));
}

test "sandbox fs: allow_wins explicitly grants exceptions" {
    const p = policy_mod.FsPolicy{
        .allowlist = &.{"/srv/public"},
        .denylist = &.{"/srv"},
        .conflict = .allow_wins,
    };
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(p, "/srv/public/index.html", .read));
    try testing.expectEqual(fs_mod.Decision.deny, fs_mod.check(p, "/srv/private/secret", .read));
}

test "sandbox fs: root prefix covers everything below it" {
    const p = policy_mod.FsPolicy{ .allowlist = &.{"/"}, .writes_allowed = true };
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(p, "/anything/goes", .read));
    try testing.expectEqual(fs_mod.Decision.allow, fs_mod.check(p, "/anything/goes", .write));
}
