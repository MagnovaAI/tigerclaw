//! Compare two runs case-by-case.
//!
//! The classic bench question is "did this change break anything?"
//! `compare` answers by pairing metrics by id and returning one
//! `Delta` per case. The hash guard (Commit 44) runs first so the
//! caller knows the inputs actually match before comparing.

const std = @import("std");
const metrics = @import("metrics.zig");

pub const Delta = struct {
    id: []const u8,
    baseline_passed: bool,
    candidate_passed: bool,
    /// null if either side has no score.
    score_delta: ?f64,
    turns_delta: i32,
    cost_delta_micros: i64,

    pub fn kind(self: Delta) Kind {
        if (!self.baseline_passed and !self.candidate_passed) return .both_fail;
        if (self.baseline_passed and self.candidate_passed) return .both_pass;
        if (self.candidate_passed) return .improved;
        return .regressed;
    }
};

pub const Kind = enum { both_pass, both_fail, improved, regressed };

/// Pair metrics by `id`. Every id from the baseline must appear in
/// the candidate; stragglers on either side are surfaced as
/// `error.UnpairedCase` so the caller cannot silently accept a
/// partial comparison.
pub fn compare(
    allocator: std.mem.Allocator,
    baseline: []const metrics.CaseMetric,
    candidate: []const metrics.CaseMetric,
) ![]Delta {
    if (baseline.len != candidate.len) return error.UnpairedCase;

    var out = try allocator.alloc(Delta, baseline.len);
    errdefer allocator.free(out);

    for (baseline, 0..) |b, i| {
        const c = findById(candidate, b.id) orelse return error.UnpairedCase;
        const score_delta = if (b.score != null and c.score != null)
            c.score.? - b.score.?
        else
            null;
        out[i] = .{
            .id = b.id,
            .baseline_passed = b.passed,
            .candidate_passed = c.passed,
            .score_delta = score_delta,
            .turns_delta = @as(i32, @intCast(c.turns)) - @as(i32, @intCast(b.turns)),
            .cost_delta_micros = @as(i64, @intCast(c.cost_micros)) - @as(i64, @intCast(b.cost_micros)),
        };
    }
    return out;
}

fn findById(list: []const metrics.CaseMetric, id: []const u8) ?metrics.CaseMetric {
    for (list) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "compare: detects improvement and regression" {
    const baseline = [_]metrics.CaseMetric{
        .{ .id = "a", .passed = false, .score = 0.2 },
        .{ .id = "b", .passed = true, .score = 0.9 },
    };
    const candidate = [_]metrics.CaseMetric{
        .{ .id = "a", .passed = true, .score = 0.95 },
        .{ .id = "b", .passed = false, .score = 0.1 },
    };
    const out = try compare(testing.allocator, &baseline, &candidate);
    defer testing.allocator.free(out);

    try testing.expectEqual(Kind.improved, out[0].kind());
    try testing.expectEqual(Kind.regressed, out[1].kind());
}

test "compare: unpaired case is rejected" {
    const baseline = [_]metrics.CaseMetric{.{ .id = "a", .passed = true }};
    const candidate = [_]metrics.CaseMetric{.{ .id = "b", .passed = true }};
    try testing.expectError(error.UnpairedCase, compare(testing.allocator, &baseline, &candidate));
}
