//! Human-readable bench reporter.
//!
//! Emits one line per case plus a trailing summary line. Kept
//! small on purpose — richer rendering (HTML, JSON-to-dashboard)
//! belongs outside the runtime.

const std = @import("std");
const metrics = @import("metrics.zig");

pub fn writeRun(
    writer: *std.Io.Writer,
    cases: []const metrics.CaseMetric,
) !void {
    for (cases) |c| {
        const status = if (c.passed) "PASS" else "FAIL";
        try writer.print("{s}\t{s}\tturns={d}\tcost={d}us\tscore=", .{
            status, c.id, c.turns, c.cost_micros,
        });
        if (c.score) |s| {
            try writer.print("{d:.3}", .{s});
        } else {
            try writer.writeAll("-");
        }
        try writer.print("\t{s}\n", .{c.outcome});
    }

    const summary = metrics.RunSummary.reduce(cases);
    try writer.print(
        "---\nruns={d} passed={d} pass_pct={d} total_cost={d}us total_turns={d}\n",
        .{
            summary.cases,
            summary.passed,
            summary.passRatePct(),
            summary.total_cost_micros,
            summary.total_turns,
        },
    );
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeRun: emits a line per case and a summary" {
    const cases = [_]metrics.CaseMetric{
        .{ .id = "alpha", .passed = true, .score = 0.95, .turns = 2, .cost_micros = 100 },
        .{ .id = "beta", .passed = false, .score = 0.5, .turns = 5, .cost_micros = 200, .outcome = "threshold" },
    };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRun(&w, &cases);

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "PASS\talpha") != null);
    try testing.expect(std.mem.indexOf(u8, text, "FAIL\tbeta") != null);
    try testing.expect(std.mem.indexOf(u8, text, "threshold") != null);
    try testing.expect(std.mem.indexOf(u8, text, "runs=2 passed=1") != null);
}
