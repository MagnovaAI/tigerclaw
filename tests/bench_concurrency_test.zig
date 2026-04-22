//! Integration tests for the bench scheduler's concurrency
//! invariant: N cases × M workers must produce exactly N metrics,
//! with each case seen exactly once, regardless of scheduling.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const bench = tigerclaw.bench;

fn stampingExec(ctx: *anyopaque, _: std.mem.Allocator, case: bench.Case) anyerror!bench.runner.Outcome {
    const seen: *std.atomic.Value(u64) = @ptrCast(@alignCast(ctx));
    // Use the case's max_turns as a per-case bit (we pre-seeded it
    // below as the case index) so we can assert every case ran.
    _ = seen.fetchOr(@as(u64, 1) << @intCast(case.max_turns), .acq_rel);
    return .{ .score = 1.0, .turns = 1, .cost_micros = 1 };
}

test "bench concurrency: 32 cases across 8 workers all run exactly once" {
    var seen = std.atomic.Value(u64).init(0);
    const exec = bench.Executor{ .ctx = @ptrCast(&seen), .fun = stampingExec };

    var cases: [32]bench.Case = undefined;
    for (&cases, 0..) |*c, i| {
        c.* = .{
            .id = "",
            .prompt = "",
            .assertion_id = "",
            .threshold = 0,
            .max_turns = @intCast(i),
            .time_budget_ms = 0,
            .cost_budget_micros = 0,
        };
    }

    const out = try bench.scheduler.schedule(
        testing.allocator,
        exec,
        &cases,
        .{ .max_concurrency = 8 },
    );
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 32), out.len);
    try testing.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(seen.load(.acquire))));
}

test "bench concurrency: sequential schedule matches parallel results" {
    var counter_a = std.atomic.Value(u64).init(0);
    var counter_b = std.atomic.Value(u64).init(0);
    const exec_a = bench.Executor{ .ctx = @ptrCast(&counter_a), .fun = stampingExec };
    const exec_b = bench.Executor{ .ctx = @ptrCast(&counter_b), .fun = stampingExec };

    var cases: [16]bench.Case = undefined;
    for (&cases, 0..) |*c, i| {
        c.* = .{
            .id = "",
            .prompt = "",
            .assertion_id = "",
            .threshold = 0,
            .max_turns = @intCast(i),
            .time_budget_ms = 0,
            .cost_budget_micros = 0,
        };
    }

    const seq = try bench.scheduler.schedule(testing.allocator, exec_a, &cases, .{ .max_concurrency = 1 });
    defer testing.allocator.free(seq);
    const par = try bench.scheduler.schedule(testing.allocator, exec_b, &cases, .{ .max_concurrency = 4 });
    defer testing.allocator.free(par);

    // Same length, same coverage mask, same pass count.
    try testing.expectEqual(seq.len, par.len);
    try testing.expectEqual(counter_a.load(.acquire), counter_b.load(.acquire));
    try testing.expectEqual(
        bench.metrics.RunSummary.reduce(seq).passed,
        bench.metrics.RunSummary.reduce(par).passed,
    );
}
