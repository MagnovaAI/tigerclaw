//! Judging rubric.
//!
//! A rubric declares the set of criteria a judge applies, each
//! with a weight and a pass threshold. Scores are aggregated as a
//! weighted mean; total weight is normalised at construction so
//! callers do not have to do it.

const std = @import("std");

pub const Criterion = struct {
    id: []const u8,
    description: []const u8,
    weight: f64,
    /// Threshold on 0..1 below which the criterion is "failed".
    threshold: f64 = 0.8,
};

pub const Rubric = struct {
    id: []const u8,
    criteria: []const Criterion,

    pub fn weightSum(self: Rubric) f64 {
        var s: f64 = 0;
        for (self.criteria) |c| s += c.weight;
        return s;
    }

    /// Compute weighted mean score. `scores.len` must equal
    /// `criteria.len`; callers supply the score for each criterion
    /// in the same order.
    pub fn weightedScore(self: Rubric, scores: []const f64) !f64 {
        if (scores.len != self.criteria.len) return error.RubricScoreMismatch;
        const total_w = self.weightSum();
        if (total_w == 0) return 0;
        var s: f64 = 0;
        for (self.criteria, scores) |c, v| s += c.weight * v;
        return s / total_w;
    }

    /// Pass predicate: every criterion must meet its threshold
    /// *and* the weighted score must meet `overall_threshold`.
    pub fn passed(
        self: Rubric,
        scores: []const f64,
        overall_threshold: f64,
    ) !bool {
        if (scores.len != self.criteria.len) return error.RubricScoreMismatch;
        for (self.criteria, scores) |c, v| {
            if (v < c.threshold) return false;
        }
        const overall = try self.weightedScore(scores);
        return overall >= overall_threshold;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Rubric.weightedScore: matches hand-computed mean" {
    const r = Rubric{
        .id = "r1",
        .criteria = &.{
            .{ .id = "a", .description = "", .weight = 1 },
            .{ .id = "b", .description = "", .weight = 3 },
        },
    };
    const score = try r.weightedScore(&.{ 1.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f64, 0.25), score, 1e-9);
}

test "Rubric.passed: any criterion below threshold fails the whole" {
    const r = Rubric{
        .id = "r",
        .criteria = &.{
            .{ .id = "a", .description = "", .weight = 1, .threshold = 0.9 },
            .{ .id = "b", .description = "", .weight = 1, .threshold = 0.5 },
        },
    };
    try testing.expect(try r.passed(&.{ 0.95, 0.6 }, 0.7));
    try testing.expect(!try r.passed(&.{ 0.85, 0.6 }, 0.7));
}

test "Rubric.weightedScore: length mismatch returns an error" {
    const r = Rubric{
        .id = "r",
        .criteria = &.{.{ .id = "a", .description = "", .weight = 1 }},
    };
    try testing.expectError(error.RubricScoreMismatch, r.weightedScore(&.{ 1, 0 }));
}
