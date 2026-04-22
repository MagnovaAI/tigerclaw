//! Integration tests for the session-mode policy.
//!
//! These pin down the externally observable contract: a session
//! mode is fixed at construction, any attempt to change it is a
//! hard error, and the capability table is the authoritative answer
//! to "may this mode do X".

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const mode_policy = tigerclaw.harness.mode_policy;

test "mode_policy: every mode pins at construction" {
    for ([_]mode_policy.Mode{ .run, .bench, .replay, .eval }) |m| {
        const p = mode_policy.Policy.init(m);
        try testing.expectEqual(m, p.current());
    }
}

test "mode_policy: transition rejects any change away from the initial mode" {
    var p = mode_policy.Policy.init(.replay);
    try testing.expectError(mode_policy.Error.ModePinned, p.transition(.run));
    try testing.expectError(mode_policy.Error.ModePinned, p.transition(.bench));
    try testing.expectError(mode_policy.Error.ModePinned, p.transition(.eval));
    try testing.expectEqual(mode_policy.Mode.replay, p.current());
}

test "mode_policy: transition to the same mode is idempotent" {
    var p = mode_policy.Policy.init(.eval);
    try p.transition(.eval);
    try p.transition(.eval);
    try testing.expectEqual(mode_policy.Mode.eval, p.current());
}

test "mode_policy: capability table matches documented rules" {
    // Table-driven assertions. If this table ever drifts out of
    // mode_policy.Capabilities.of(), that is a breaking change worth
    // surfacing explicitly rather than silently.
    const Case = struct {
        mode: mode_policy.Mode,
        live_network: bool,
        wall_clock: bool,
        filesystem_writes: bool,
        subprocess_spawn: bool,
    };
    const cases = [_]Case{
        .{ .mode = .run, .live_network = true, .wall_clock = true, .filesystem_writes = true, .subprocess_spawn = true },
        .{ .mode = .bench, .live_network = false, .wall_clock = false, .filesystem_writes = true, .subprocess_spawn = false },
        .{ .mode = .replay, .live_network = false, .wall_clock = false, .filesystem_writes = false, .subprocess_spawn = false },
        .{ .mode = .eval, .live_network = false, .wall_clock = false, .filesystem_writes = true, .subprocess_spawn = false },
    };
    for (cases) |c| {
        const caps = mode_policy.Policy.init(c.mode).capabilities();
        try testing.expectEqual(c.live_network, caps.live_network);
        try testing.expectEqual(c.wall_clock, caps.wall_clock);
        try testing.expectEqual(c.filesystem_writes, caps.filesystem_writes);
        try testing.expectEqual(c.subprocess_spawn, caps.subprocess_spawn);
    }
}

test "mode_policy: require rejects unlisted modes" {
    const p = mode_policy.Policy.init(.run);
    try p.require(&.{.run});
    try testing.expectError(error.ModeNotAllowed, p.require(&.{ .bench, .replay, .eval }));
}
