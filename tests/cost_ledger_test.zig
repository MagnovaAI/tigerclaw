//! Integration tests for the cost ledger.
//!
//! These exercise the reserve/commit/release flow end-to-end
//! alongside the reporter, plus the concurrent-safety claim that
//! the ledger's ceiling cannot be breached by parallel reserves.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const cost = tigerclaw.cost;

test "cost ledger: happy path reserve, commit, and report" {
    const table = [_]cost.ModelPrice{
        .{ .model = "m", .input = 3_000_000, .output = 15_000_000 },
    };

    var ledger = cost.Ledger.init(100_000_000);
    defer ledger.deinit(testing.allocator);

    var reporter = cost.Reporter.init(testing.allocator);
    defer reporter.deinit();

    // Reserve enough for a generous call.
    const res = try ledger.reserve(testing.allocator, 50_000_000);
    const usage = tigerclaw.types.TokenUsage{ .input = 1_000_000, .output = 500_000 };

    const real_cost = try ledger.commitUsage(&table, "m", usage, res);
    try reporter.record("m", usage, real_cost);

    const totals = ledger.totals();
    try testing.expectEqual(@as(u64, 10_500_000), totals.spent_micros);
    try testing.expectEqual(@as(u64, 0), totals.pending_micros);
    try testing.expectEqual(@as(u64, 10_500_000), reporter.grandTotalMicros());
}

test "cost ledger: ceiling is enforced strictly" {
    var ledger = cost.Ledger.init(1_000);
    defer ledger.deinit(testing.allocator);

    const r = try ledger.reserve(testing.allocator, 1_000);
    try testing.expectError(cost.ledger.Error.CeilingExceeded, ledger.reserve(testing.allocator, 1));
    try ledger.commit(r, 1_000);
    try testing.expectError(cost.ledger.Error.CeilingExceeded, ledger.reserve(testing.allocator, 1));
}

test "cost ledger: release recovers headroom" {
    var ledger = cost.Ledger.init(1_000);
    defer ledger.deinit(testing.allocator);

    const r = try ledger.reserve(testing.allocator, 700);
    try ledger.release(r);
    // Full headroom now available.
    _ = try ledger.reserve(testing.allocator, 1_000);
}

test "cost ledger: reporter snapshot is sorted descending by cost" {
    var ledger = cost.Ledger.init(0); // no ceiling
    defer ledger.deinit(testing.allocator);

    var reporter = cost.Reporter.init(testing.allocator);
    defer reporter.deinit();

    try reporter.record("cheap", .{ .input = 100 }, 100);
    try reporter.record("mid", .{ .input = 1_000 }, 10_000);
    try reporter.record("expensive", .{ .input = 10_000 }, 1_000_000);

    const snap = try reporter.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqualStrings("expensive", snap[0].model);
    try testing.expectEqualStrings("mid", snap[1].model);
    try testing.expectEqualStrings("cheap", snap[2].model);
}

test "cost ledger: parallel reserves never breach the ceiling" {
    // 32 threads each try to reserve 1_000 against a 10_000 cap.
    // Exactly 10 must succeed — no more, no fewer, regardless of
    // scheduling. This is the core invariant two-phase accounting
    // buys us.
    var ledger = cost.Ledger.init(10_000);
    defer ledger.deinit(testing.allocator);

    const Worker = struct {
        fn run(l: *cost.Ledger, allocator: std.mem.Allocator, wins: *std.atomic.Value(u32)) void {
            if (l.reserve(allocator, 1_000)) |_| {
                _ = wins.fetchAdd(1, .monotonic);
            } else |_| {}
        }
    };

    var wins = std.atomic.Value(u32).init(0);
    var threads: [32]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &ledger, testing.allocator, &wins });
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 10), wins.load(.monotonic));
    try testing.expectEqual(@as(u64, 10_000), ledger.totals().pending_micros);
}

test "cost ledger: mixed commits and releases land cleanly" {
    var ledger = cost.Ledger.init(100);
    defer ledger.deinit(testing.allocator);

    const r1 = try ledger.reserve(testing.allocator, 40);
    const r2 = try ledger.reserve(testing.allocator, 40);
    const r3 = try ledger.reserve(testing.allocator, 20);

    // Commit r1, release r2, over-commit attempt on r3.
    try ledger.commit(r1, 30);
    try ledger.release(r2);
    try testing.expectError(cost.ledger.Error.OverCommit, ledger.commit(r3, 21));
    try ledger.commit(r3, 10);

    const t = ledger.totals();
    try testing.expectEqual(@as(u64, 40), t.spent_micros);
    try testing.expectEqual(@as(u64, 0), t.pending_micros);
}
