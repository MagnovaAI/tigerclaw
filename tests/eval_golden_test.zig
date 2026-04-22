//! Integration tests for the eval dataset + golden + report flow.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const eval = tigerclaw.eval;

test "dataset + golden: match by scenario_id drives pass/fail" {
    const dataset_src =
        \\{"scenario_id":"a","input":"hi"}
        \\{"scenario_id":"b","input":"bye"}
    ;
    const golden_src =
        \\{"scenario_id":"a","expected":"hello"}
        \\{"scenario_id":"b","expected":"goodbye"}
    ;

    const ds = try eval.dataset.parseJsonl(testing.allocator, dataset_src);
    defer eval.dataset.free(testing.allocator, ds);
    const gs = try eval.golden.parseJsonl(testing.allocator, golden_src);
    defer eval.golden.free(testing.allocator, gs);

    try testing.expectEqualStrings("hello", eval.golden.lookup(gs, "a").?);
    try testing.expectEqualStrings("goodbye", eval.golden.lookup(gs, "b").?);
    try testing.expect(eval.golden.lookup(gs, "missing") == null);
}

test "report: aggregates outcomes into pass rate" {
    const outs = [_]eval.Outcome{
        .{ .scenario_id = "a", .passed = true, .score = 1.0, .reason = "ok" },
        .{ .scenario_id = "b", .passed = false, .score = 0.0, .reason = "miss" },
        .{ .scenario_id = "c", .passed = true, .score = 0.9, .reason = "ok" },
    };
    const r = eval.Report{ .outcomes = &outs };
    try testing.expectEqual(@as(u32, 2), r.passed());
    try testing.expectEqual(@as(u32, 66), r.passRatePct());

    const json = try eval.report.renderJson(testing.allocator, r);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"passed\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\":3") != null);
}
