//! Integration tests for the harness top-level orchestrator.
//!
//! These exercise the public `Harness` surface the CLI uses: start a
//! session, save it, resume it through a freshly-constructed harness,
//! and verify that the on-disk file is valid JSON and forward-
//! compatible. Unit coverage of individual modules lives in their
//! source files.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const harness_mod = tigerclaw.harness.harness;
const state_mod = tigerclaw.harness.state;
const clock_mod = tigerclaw.clock;

test "harness: two independent harnesses share state via the state dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Writer harness.
    {
        var mc = clock_mod.ManualClock{ .value_ns = 10 };
        var h = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        });
        var s = try h.startSession("shared-1");
        defer s.deinit();
        try s.appendTurn("ping", "pong");
        mc.advance(5);
        try s.appendTurn("again", "yes");
        try h.saveSession(&s);
    }

    // Reader harness simulates a second process running with --resume.
    {
        var mc = clock_mod.ManualClock{ .value_ns = 0 };
        var h = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        });
        var resumed = try h.resumeSession("shared-1");
        defer resumed.deinit();
        try testing.expectEqual(@as(u32, 2), resumed.turnCount());
        try testing.expectEqualStrings("pong", resumed.turns.items[0].assistant.flatText());
        try testing.expectEqualStrings("yes", resumed.turns.items[1].assistant.flatText());
    }
}

test "harness: saved file carries the stamped schema version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 42 };
    var h = harness_mod.Harness.init(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
    });
    var s = try h.startSession("schema-check");
    defer s.deinit();
    try s.appendTurn("u", "a");
    try h.saveSession(&s);

    var buf: [8 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "schema-check.json", &buf);

    // Schema version must match the exported constant so consumers can
    // gate compatibility checks on a single source of truth.
    const parsed = try state_mod.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(state_mod.schema_version, parsed.value.schema_version);
    try testing.expectEqualStrings("schema-check", parsed.value.id);
}

test "harness: append after resume extends the stored history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var h = harness_mod.Harness.init(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
    });

    {
        var s = try h.startSession("grow");
        defer s.deinit();
        try s.appendTurn("one", "1");
        try h.saveSession(&s);
    }

    {
        mc.advance(100);
        var s = try h.resumeSession("grow");
        defer s.deinit();
        try s.appendTurn("two", "2");
        try h.saveSession(&s);
        try testing.expectEqual(@as(u32, 2), s.turnCount());
    }

    {
        var s = try h.resumeSession("grow");
        defer s.deinit();
        try testing.expectEqual(@as(u32, 2), s.turnCount());
        try testing.expectEqualStrings("1", s.turns.items[0].assistant.flatText());
        try testing.expectEqualStrings("2", s.turns.items[1].assistant.flatText());
    }
}
