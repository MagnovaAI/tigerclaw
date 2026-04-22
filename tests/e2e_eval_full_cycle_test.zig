//! E2E eval: dataset + golden + judge + rubric + report. Runs a
//! full read-dataset → compare-against-golden → judge → aggregate
//! cycle end to end so any drift in any one piece is caught by
//! the whole flow.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const eval = tigerclaw.eval;

test "e2e eval: full cycle from dataset+golden through report" {
    const dataset_src =
        \\{"scenario_id":"one","input":"hello"}
        \\{"scenario_id":"two","input":"world"}
    ;
    const golden_src =
        \\{"scenario_id":"one","expected":"hello"}
        \\{"scenario_id":"two","expected":"world"}
    ;

    const ds = try eval.dataset.parseJsonl(testing.allocator, dataset_src);
    defer eval.dataset.free(testing.allocator, ds);
    const gs = try eval.golden.parseJsonl(testing.allocator, golden_src);
    defer eval.golden.free(testing.allocator, gs);

    const r = eval.Rubric{
        .id = "default",
        .criteria = &.{.{ .id = "match", .description = "", .weight = 1, .threshold = 0.5 }},
    };

    var outcomes: [2]eval.Outcome = undefined;
    for (ds, 0..) |item, i| {
        const expected = eval.golden.lookup(gs, item.scenario_id).?;
        // Observed text matches golden exactly for one, differs
        // for the other so we can assert both branches.
        const observed = if (i == 0) expected else "totally wrong";
        const j = try eval.judge.judge(testing.allocator, r, observed, expected);
        defer j.deinit(testing.allocator);
        const passed = try r.passed(j.per_criterion, 0.7);
        outcomes[i] = .{
            .scenario_id = item.scenario_id,
            .passed = passed,
            .score = j.per_criterion[0],
            .reason = if (passed) "ok" else "below_threshold",
        };
    }

    const report = eval.Report{ .outcomes = &outcomes };
    try testing.expectEqual(@as(u32, 1), report.passed());
    try testing.expectEqual(@as(u32, 50), report.passRatePct());

    const json = try eval.report.renderJson(testing.allocator, report);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"passed\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":2") != null);
}
