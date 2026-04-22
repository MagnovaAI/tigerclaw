//! Eval reporter.
//!
//! The eval harness accumulates per-scenario outcomes into a
//! `Report` and renders a short JSON summary. Kept machine-
//! readable so CI jobs can grep it; a prettier human renderer
//! lives in `bench/reporter.zig` for bench runs.

const std = @import("std");

pub const Outcome = struct {
    scenario_id: []const u8,
    passed: bool,
    /// Score produced by the judge/assertion.
    score: f64,
    /// Free-form reason string for the log ("golden_match",
    /// "threshold=0.9 score=0.72", "no_golden_for_id").
    reason: []const u8,
};

pub const Report = struct {
    outcomes: []const Outcome,

    pub fn passed(self: Report) u32 {
        var n: u32 = 0;
        for (self.outcomes) |o| if (o.passed) {
            n += 1;
        };
        return n;
    }

    pub fn passRatePct(self: Report) u32 {
        if (self.outcomes.len == 0) return 0;
        return @intCast(@as(u64, self.passed()) * 100 / self.outcomes.len);
    }
};

/// Render a JSON summary:
///   `{ "passed": N, "total": M, "pass_pct": P, "outcomes": [ ... ] }`
pub fn renderJson(
    allocator: std.mem.Allocator,
    report: Report,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"passed\":");
    var nbuf: [20]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&nbuf, "{d}", .{report.passed()}));
    try buf.appendSlice(allocator, ",\"total\":");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&nbuf, "{d}", .{report.outcomes.len}));
    try buf.appendSlice(allocator, ",\"pass_pct\":");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&nbuf, "{d}", .{report.passRatePct()}));
    try buf.appendSlice(allocator, ",\"outcomes\":[");

    for (report.outcomes, 0..) |o, i| {
        if (i != 0) try buf.append(allocator, ',');
        const line = try std.json.Stringify.valueAlloc(allocator, o, .{});
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Report.passed / passRatePct: counts and percents" {
    const outs = [_]Outcome{
        .{ .scenario_id = "a", .passed = true, .score = 1.0, .reason = "ok" },
        .{ .scenario_id = "b", .passed = false, .score = 0.0, .reason = "nope" },
    };
    const r = Report{ .outcomes = &outs };
    try testing.expectEqual(@as(u32, 1), r.passed());
    try testing.expectEqual(@as(u32, 50), r.passRatePct());
}

test "renderJson: emits a summary envelope and outcomes" {
    const outs = [_]Outcome{
        .{ .scenario_id = "s", .passed = true, .score = 0.95, .reason = "ok" },
    };
    const bytes = try renderJson(testing.allocator, .{ .outcomes = &outs });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"passed\":1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"pass_pct\":100") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"scenario_id\":\"s\"") != null);
}
