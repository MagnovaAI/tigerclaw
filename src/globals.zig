//! Process-wide runtime slots.
//!
//! Kept deliberately small. Anything that smells like per-session or per-
//! agent state belongs in `harness/state.zig` once that subsystem lands —
//! not here.

const std = @import("std");

/// Build profile. Set once during startup; never mutated afterwards.
pub const Profile = enum {
    debug,
    release,
    bench,
    replay,
};

var profile: Profile = .debug;

pub fn setProfile(p: Profile) void {
    profile = p;
}

pub fn getProfile() Profile {
    return profile;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "profile: default is .debug" {
    try testing.expectEqual(Profile.debug, getProfile());
}

test "profile: set then get roundtrips" {
    defer setProfile(.debug);
    setProfile(.bench);
    try testing.expectEqual(Profile.bench, getProfile());
}
