//! Integration tests for the bench hash guard and the guarded
//! compare flow: matching tuples run compare, mismatched tuples
//! refuse.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const bench = tigerclaw.bench;

test "hash guard: sha256Hex is deterministic" {
    const a = try bench.hash_guard.sha256Hex(testing.allocator, "payload");
    defer bench.hash_guard.freeDigest(testing.allocator, a);
    const b = try bench.hash_guard.sha256Hex(testing.allocator, "payload");
    defer bench.hash_guard.freeDigest(testing.allocator, b);
    try testing.expectEqualStrings(a.hex, b.hex);
}

test "hash guard: matching tuples allow compareGuarded" {
    const h = try bench.hash_guard.sha256Hex(testing.allocator, "dataset-bytes");
    defer bench.hash_guard.freeDigest(testing.allocator, h);

    const tup = bench.HashTuple{ .dataset = h };
    const baseline = [_]bench.CaseMetric{.{ .id = "a", .passed = true, .score = 0.9 }};
    const candidate = [_]bench.CaseMetric{.{ .id = "a", .passed = true, .score = 0.95 }};

    const deltas = try bench.compare.compareGuarded(
        testing.allocator,
        &baseline,
        tup,
        &candidate,
        tup,
    );
    defer testing.allocator.free(deltas);
    try testing.expectEqual(@as(usize, 1), deltas.len);
}

test "hash guard: mismatched dataset refuses compareGuarded" {
    const a = try bench.hash_guard.sha256Hex(testing.allocator, "a");
    defer bench.hash_guard.freeDigest(testing.allocator, a);
    const b = try bench.hash_guard.sha256Hex(testing.allocator, "b");
    defer bench.hash_guard.freeDigest(testing.allocator, b);

    const baseline = [_]bench.CaseMetric{.{ .id = "x", .passed = true }};
    const candidate = [_]bench.CaseMetric{.{ .id = "x", .passed = true }};

    try testing.expectError(
        bench.compare.Error.HashMismatch,
        bench.compare.compareGuarded(
            testing.allocator,
            &baseline,
            .{ .dataset = a },
            &candidate,
            .{ .dataset = b },
        ),
    );
}

test "hash guard: unset on both sides compares fine" {
    const baseline = [_]bench.CaseMetric{.{ .id = "x", .passed = true }};
    const candidate = [_]bench.CaseMetric{.{ .id = "x", .passed = false }};
    const deltas = try bench.compare.compareGuarded(
        testing.allocator,
        &baseline,
        .{},
        &candidate,
        .{},
    );
    defer testing.allocator.free(deltas);
    try testing.expectEqual(bench.compare.Kind.regressed, deltas[0].kind());
}
