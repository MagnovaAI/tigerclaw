//! Judge.
//!
//! Scores an observed output against a rubric. For this commit we
//! ship a deterministic heuristic judge (length ratio + substring
//! overlap) — an LLM-assisted judge slots in behind the same
//! signature later.
//!
//! The judge returns a vector of per-criterion scores; rubric
//! aggregation and thresholding are the caller's job so a single
//! judge implementation can serve many rubrics.

const std = @import("std");
const rubric_mod = @import("rubric.zig");

pub const Judgement = struct {
    per_criterion: []f64,

    pub fn deinit(self: Judgement, allocator: std.mem.Allocator) void {
        allocator.free(self.per_criterion);
    }
};

/// Heuristic judge:
///   * For every criterion, compute a 0..1 score based on:
///     - 0.5 weight for length ratio (min/max of observed vs
///       expected byte counts).
///     - 0.5 weight for token overlap (share of whitespace-split
///       tokens from `expected` that also appear in `observed`).
///
/// This is a cheap, deterministic signal; calibration comes from
/// picking thresholds in the rubric, not from the judge.
pub fn judge(
    allocator: std.mem.Allocator,
    r: rubric_mod.Rubric,
    observed: []const u8,
    expected: []const u8,
) !Judgement {
    const scores = try allocator.alloc(f64, r.criteria.len);
    errdefer allocator.free(scores);

    const len_score = lengthRatio(observed, expected);
    const overlap = tokenOverlap(observed, expected);
    const v = 0.5 * len_score + 0.5 * overlap;

    for (scores) |*s| s.* = v;
    return .{ .per_criterion = scores };
}

fn lengthRatio(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 and b.len == 0) return 1;
    const num: f64 = @floatFromInt(@min(a.len, b.len));
    const den: f64 = @floatFromInt(@max(a.len, b.len));
    return num / den;
}

fn tokenOverlap(observed: []const u8, expected: []const u8) f64 {
    var total: f64 = 0;
    var hits: f64 = 0;
    var it = std.mem.tokenizeAny(u8, expected, " \t\n\r");
    while (it.next()) |tok| {
        total += 1;
        if (std.mem.indexOf(u8, observed, tok) != null) hits += 1;
    }
    if (total == 0) return 1;
    return hits / total;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "judge: exact match scores 1.0" {
    const r = rubric_mod.Rubric{
        .id = "r",
        .criteria = &.{.{ .id = "a", .description = "", .weight = 1 }},
    };
    const j = try judge(testing.allocator, r, "hello world", "hello world");
    defer j.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 1.0), j.per_criterion[0], 1e-9);
}

test "judge: total mismatch scores near 0" {
    const r = rubric_mod.Rubric{
        .id = "r",
        .criteria = &.{.{ .id = "a", .description = "", .weight = 1 }},
    };
    const j = try judge(testing.allocator, r, "x", "completely different text");
    defer j.deinit(testing.allocator);
    try testing.expect(j.per_criterion[0] < 0.3);
}

test "judge: partial overlap falls in between" {
    const r = rubric_mod.Rubric{
        .id = "r",
        .criteria = &.{
            .{ .id = "a", .description = "", .weight = 1 },
            .{ .id = "b", .description = "", .weight = 1 },
        },
    };
    const j = try judge(testing.allocator, r, "hello zig", "hello world");
    defer j.deinit(testing.allocator);
    try testing.expect(j.per_criterion[0] > 0.5);
    try testing.expect(j.per_criterion[0] < 1.0);
}
