//! Cross-run aggregation.
//!
//! The scheduler emits per-case metrics; the aggregator reduces a
//! whole run to a single `RunSummary` and optionally groups by a
//! caller-supplied key (usually model id). Kept separate from
//! `metrics.RunSummary.reduce` so group-by logic does not live on
//! the primitive metric type.

const std = @import("std");
const metrics = @import("metrics.zig");

pub const GroupedSummary = struct {
    key: []const u8,
    summary: metrics.RunSummary,
};

/// Produce per-key summaries. `key_fn` maps each case to its
/// group key; keys are compared byte-for-byte (no normalisation).
/// Output is sorted by key for deterministic reporting.
pub fn groupBy(
    allocator: std.mem.Allocator,
    cases: []const metrics.CaseMetric,
    key_fn: *const fn (c: metrics.CaseMetric) []const u8,
) ![]GroupedSummary {
    var map = std.StringHashMap(metrics.RunSummary).init(allocator);
    defer map.deinit();

    for (cases) |c| {
        const gop = try map.getOrPut(key_fn(c));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.cases += 1;
        if (c.passed) gop.value_ptr.passed += 1;
        gop.value_ptr.total_duration_ns +|= c.duration_ns;
        gop.value_ptr.total_turns +|= c.turns;
        gop.value_ptr.total_cost_micros +|= c.cost_micros;
    }

    var out = try allocator.alloc(GroupedSummary, map.count());
    errdefer allocator.free(out);

    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .key = e.key_ptr.*, .summary = e.value_ptr.* };
    }
    std.mem.sort(GroupedSummary, out, {}, cmpKey);
    return out;
}

fn cmpKey(_: void, a: GroupedSummary, b: GroupedSummary) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn keyById(c: metrics.CaseMetric) []const u8 {
    return c.id;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "groupBy: sums per id and returns sorted output" {
    const cases = [_]metrics.CaseMetric{
        .{ .id = "y", .passed = true, .turns = 1, .cost_micros = 10 },
        .{ .id = "x", .passed = true, .turns = 2, .cost_micros = 20 },
        .{ .id = "x", .passed = false, .turns = 3, .cost_micros = 30 },
    };
    const out = try groupBy(testing.allocator, &cases, keyById);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("x", out[0].key);
    try testing.expectEqual(@as(u32, 2), out[0].summary.cases);
    try testing.expectEqual(@as(u32, 1), out[0].summary.passed);
    try testing.expectEqual(@as(u64, 50), out[0].summary.total_cost_micros);
    try testing.expectEqualStrings("y", out[1].key);
}
