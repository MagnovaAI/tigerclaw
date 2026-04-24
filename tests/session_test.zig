//! Integration tests for `Session` covering the behaviours the harness
//! relies on: stable ids across save/resume, deterministic timestamps
//! under an injected clock, and atomic save semantics.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const session_mod = tigerclaw.harness.session;
const state_mod = tigerclaw.harness.state;
const clock_mod = tigerclaw.clock;
const ResumeError = session_mod.ResumeError;

test "session: id and created_at survive a save/resume cycle" {
    var mc = clock_mod.ManualClock{ .value_ns = 500 };
    var original = try session_mod.Session.start(testing.allocator, mc.clock(), "stable-id");
    defer original.deinit();
    try original.appendTurn("hi", "hello");

    const bytes = try original.toJson();
    defer testing.allocator.free(bytes);

    // Resume with a clock that reports a completely different time —
    // created_at must stay pinned to the original value.
    var mc2 = clock_mod.ManualClock{ .value_ns = 999_999 };
    var resumed = try session_mod.Session.resumeFromBytes(
        testing.allocator,
        mc2.clock(),
        bytes,
    );
    defer resumed.deinit();

    try testing.expectEqualStrings("stable-id", resumed.id());
    try testing.expectEqual(@as(i128, 500), resumed.created_at_ns);
}

test "session: turn timestamps follow the injected clock deterministically" {
    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var s = try session_mod.Session.start(testing.allocator, mc.clock(), "ts");
    defer s.deinit();

    try s.appendTurn("q1", "a1");
    mc.advance(1_000);
    try s.appendTurn("q2", "a2");
    mc.advance(2_500);
    try s.appendTurn("q3", "a3");

    try testing.expectEqual(@as(i128, 0), s.turns.items[0].started_at_ns);
    try testing.expectEqual(@as(i128, 1_000), s.turns.items[1].started_at_ns);
    try testing.expectEqual(@as(i128, 3_500), s.turns.items[2].started_at_ns);
    try testing.expectEqual(@as(i128, 3_500), s.updated_at_ns);
}

test "session: save writes the target file atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var s = try session_mod.Session.start(testing.allocator, mc.clock(), "atomic");
    defer s.deinit();
    try s.appendTurn("u", "a");
    try s.save(tmp.dir, testing.io, "atomic.json");

    // File must exist and be readable as valid JSON. The atomic
    // tmp-rename contract is enforced by `internal_writes.writeAtomic`
    // (covered by its own tests); here we only assert the observable
    // outcome from the session's perspective.
    var buf: [4 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "atomic.json", &buf);
    const parsed = try tigerclaw.harness.state.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqualStrings("atomic", parsed.value.id);
}

test "session: snapshot reflects live turns without copying" {
    var mc = clock_mod.ManualClock{ .value_ns = 7 };
    var s = try session_mod.Session.start(testing.allocator, mc.clock(), "snap");
    defer s.deinit();
    try s.appendTurn("a", "b");

    const snap = s.snapshot();
    try testing.expectEqual(@as(u32, 1), snap.turn_count);
    try testing.expectEqual(state_mod.schema_version, snap.schema_version);
    try testing.expectEqual(@as(usize, 1), snap.turns.len);
    try testing.expectEqualStrings("a", snap.turns[0].user.flatText());
}
