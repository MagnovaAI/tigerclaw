//! Per-case measurement record.
//!
//! A `CaseMetric` captures what happened when one scenario was run
//! against one agent configuration. All fields are primitive so
//! the record can be JSON-serialised, summed, and compared across
//! runs without chasing pointers.

const std = @import("std");

pub const CaseMetric = struct {
    id: []const u8,
    /// Whether the assertion met the declared threshold.
    passed: bool,
    /// Raw score the judge/assertion produced (0..1 for most
    /// rubrics). `null` if no score was produced (hard-fail).
    score: ?f64 = null,
    /// End-to-end wall time for the case. Zero in replay mode.
    duration_ns: i128 = 0,
    /// Turns consumed by the react loop.
    turns: u32 = 0,
    /// Accumulated cost in micro-USD.
    cost_micros: u64 = 0,
    /// Reason the case stopped — "ok", "threshold", "timeout",
    /// "error:<id>", etc. Kept as a short string so CI logs are
    /// greppable without a secondary enum lookup.
    outcome: []const u8 = "ok",
};

/// Aggregate across a list of CaseMetrics.
pub const RunSummary = struct {
    cases: u32 = 0,
    passed: u32 = 0,
    total_duration_ns: i128 = 0,
    total_turns: u64 = 0,
    total_cost_micros: u64 = 0,

    pub fn reduce(cases: []const CaseMetric) RunSummary {
        var s = RunSummary{};
        for (cases) |c| {
            s.cases += 1;
            if (c.passed) s.passed += 1;
            s.total_duration_ns +|= c.duration_ns;
            s.total_turns +|= c.turns;
            s.total_cost_micros +|= c.cost_micros;
        }
        return s;
    }

    pub fn passRatePct(self: RunSummary) u32 {
        if (self.cases == 0) return 0;
        return @intCast(@as(u64, self.passed) * 100 / self.cases);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "RunSummary.reduce: sums and counts pass" {
    const cases = [_]CaseMetric{
        .{ .id = "a", .passed = true, .duration_ns = 1, .turns = 2, .cost_micros = 100 },
        .{ .id = "b", .passed = false, .duration_ns = 3, .turns = 1, .cost_micros = 50 },
        .{ .id = "c", .passed = true, .duration_ns = 2, .turns = 3, .cost_micros = 200 },
    };
    const s = RunSummary.reduce(&cases);
    try testing.expectEqual(@as(u32, 3), s.cases);
    try testing.expectEqual(@as(u32, 2), s.passed);
    try testing.expectEqual(@as(i128, 6), s.total_duration_ns);
    try testing.expectEqual(@as(u64, 6), s.total_turns);
    try testing.expectEqual(@as(u64, 350), s.total_cost_micros);
    try testing.expectEqual(@as(u32, 66), s.passRatePct());
}

test "RunSummary.passRatePct: empty run is zero" {
    const s = RunSummary.reduce(&.{});
    try testing.expectEqual(@as(u32, 0), s.passRatePct());
}
