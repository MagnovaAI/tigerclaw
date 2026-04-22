//! Integration tests for the session budget.
//!
//! These assert the public accounting contract the react loop depends
//! on: monotonic accumulation, per-axis tripping, and snapshot
//! coherence under concurrent writers (the budget will be touched by
//! any future background thread that bills tokens, e.g. a streaming
//! response reader).

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const budget_mod = tigerclaw.harness.budget;

test "budget: single snapshot sums the recorded axes" {
    var b = budget_mod.Budget.init(.{});
    b.recordTurn(100, 50, 2_500);
    b.recordTurn(200, 25, 500);
    const u = b.snapshot();
    try testing.expectEqual(@as(u64, 2), u.turns);
    try testing.expectEqual(@as(u64, 300), u.input_tokens);
    try testing.expectEqual(@as(u64, 75), u.output_tokens);
    try testing.expectEqual(@as(u64, 3_000), u.cost_micros);
}

test "budget: distinct axes trip independently" {
    // Turn cap only.
    var b1 = budget_mod.Budget.init(.{ .turns = 1 });
    b1.recordTurn(9_999, 9_999, 9_999);
    try testing.expectEqual(budget_mod.ExceededAxis.turns, b1.exceeded());

    // Output-token cap only; input far above its non-cap.
    var b2 = budget_mod.Budget.init(.{ .output_tokens = 10 });
    b2.recordTurn(1_000_000, 5, 0);
    try testing.expectEqual(budget_mod.ExceededAxis.none, b2.exceeded());
    b2.recordTurn(0, 5, 0);
    try testing.expectEqual(budget_mod.ExceededAxis.output_tokens, b2.exceeded());
}

test "budget: concurrent recorders preserve totals" {
    // Exercises the internal mutex: N threads each record M turns of
    // unit value; the final snapshot must equal N * M on every axis.
    const thread_count: u32 = 8;
    const per_thread: u32 = 500;

    var b = budget_mod.Budget.init(.{});

    const Worker = struct {
        fn run(ptr: *budget_mod.Budget, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) ptr.recordTurn(1, 1, 1);
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &b, per_thread });
    }
    for (threads) |t| t.join();

    const u = b.snapshot();
    const expected: u64 = @as(u64, thread_count) * @as(u64, per_thread);
    try testing.expectEqual(expected, u.turns);
    try testing.expectEqual(expected, u.input_tokens);
    try testing.expectEqual(expected, u.output_tokens);
    try testing.expectEqual(expected, u.cost_micros);
}

test "budget: isExhausted matches exceeded()" {
    var b = budget_mod.Budget.init(.{ .turns = 1 });
    try testing.expect(!b.isExhausted());
    b.recordTurn(0, 0, 0);
    try testing.expect(b.isExhausted());
    try testing.expectEqual(budget_mod.ExceededAxis.turns, b.exceeded());
}
