//! E2E bench: schedule three cases through a deterministic
//! executor, reduce into a summary, then run compareGuarded
//! against an "identical prior run" to prove the full flow
//! — scenario → case → run → metrics → compare — wires end to end.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const bench = tigerclaw.bench;

fn scoreExec(ctx: *anyopaque, _: std.mem.Allocator, case: bench.Case) anyerror!bench.runner.Outcome {
    _ = ctx;
    // Score is deterministic from the case id length so two runs
    // against the same cases produce identical metrics.
    const score = @as(f64, @floatFromInt(case.id.len)) / 10.0;
    return .{ .score = score, .turns = @intCast(case.id.len), .cost_micros = case.id.len * 100 };
}

test "e2e bench: schedule -> metrics -> guarded compare" {
    const cases = [_]bench.Case{
        .{ .id = "a", .prompt = "", .assertion_id = "", .threshold = 0.05, .max_turns = 0, .time_budget_ms = 0, .cost_budget_micros = 0 },
        .{ .id = "bb", .prompt = "", .assertion_id = "", .threshold = 0.05, .max_turns = 0, .time_budget_ms = 0, .cost_budget_micros = 0 },
        .{ .id = "ccc", .prompt = "", .assertion_id = "", .threshold = 0.05, .max_turns = 0, .time_budget_ms = 0, .cost_budget_micros = 0 },
    };

    var noop: u8 = 0;
    const exec = bench.Executor{ .ctx = @ptrCast(&noop), .fun = scoreExec };

    const baseline = try bench.scheduler.schedule(testing.allocator, exec, &cases, .{});
    defer testing.allocator.free(baseline);
    const candidate = try bench.scheduler.schedule(testing.allocator, exec, &cases, .{});
    defer testing.allocator.free(candidate);

    const hashes = bench.HashTuple{};
    const deltas = try bench.compare.compareGuarded(
        testing.allocator,
        baseline,
        hashes,
        candidate,
        hashes,
    );
    defer testing.allocator.free(deltas);

    try testing.expectEqual(@as(usize, 3), deltas.len);
    for (deltas) |d| try testing.expectEqual(bench.compare.Kind.both_pass, d.kind());

    const summary = bench.metrics.RunSummary.reduce(candidate);
    try testing.expectEqual(@as(u32, 3), summary.cases);
    try testing.expectEqual(@as(u32, 3), summary.passed);
}
