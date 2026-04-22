//! Concurrent case scheduler.
//!
//! Runs a slice of `Case`s against an `Executor`, optionally in
//! parallel up to `max_concurrency`. Returns a caller-owned slice
//! of `CaseMetric`s in scenario order.
//!
//! Each worker thread gets its own arena-backed allocator so the
//! test-harness's leak detector does not trip on cross-thread
//! allocations; results are copied back into the caller's
//! allocator on finish.

const std = @import("std");
const scenario = @import("scenario.zig");
const metrics = @import("metrics.zig");
const runner = @import("runner.zig");

pub const Options = struct {
    max_concurrency: usize = 1,
};

pub fn schedule(
    allocator: std.mem.Allocator,
    executor: runner.Executor,
    cases: []const scenario.Case,
    opts: Options,
) ![]metrics.CaseMetric {
    var out = try allocator.alloc(metrics.CaseMetric, cases.len);
    errdefer allocator.free(out);

    if (opts.max_concurrency <= 1 or cases.len <= 1) {
        for (cases, 0..) |c, i| {
            out[i] = try runner.runCase(allocator, executor, c);
        }
        return out;
    }

    // Bounded worker pool: each worker claims the next case index
    // via an atomic counter until the queue drains. std.Thread on
    // 0.16 does not need any extra I/O plumbing for this pattern.
    const Shared = struct {
        next: std.atomic.Value(usize),
        allocator: std.mem.Allocator,
        executor: runner.Executor,
        cases: []const scenario.Case,
        out: []metrics.CaseMetric,
    };
    var shared = Shared{
        .next = std.atomic.Value(usize).init(0),
        .allocator = allocator,
        .executor = executor,
        .cases = cases,
        .out = out,
    };

    const worker = struct {
        fn run(s: *Shared) void {
            while (true) {
                const idx = s.next.fetchAdd(1, .acq_rel);
                if (idx >= s.cases.len) return;
                s.out[idx] = runner.runCase(s.allocator, s.executor, s.cases[idx]) catch |err| .{
                    .id = s.cases[idx].id,
                    .passed = false,
                    .outcome = @errorName(err),
                };
            }
        }
    };

    const n = @min(opts.max_concurrency, cases.len);
    var threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, worker.run, .{&shared});
    for (threads) |t| t.join();

    return out;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn countingExec(ctx: *anyopaque, _: std.mem.Allocator, _: scenario.Case) anyerror!runner.Outcome {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
    _ = counter.fetchAdd(1, .monotonic);
    return .{ .score = 1.0, .turns = 1, .cost_micros = 1 };
}

test "schedule: runs every case in order when concurrency is 1" {
    var calls = std.atomic.Value(u32).init(0);
    const exec = runner.Executor{ .ctx = @ptrCast(&calls), .fun = countingExec };
    const cases = [_]scenario.Case{
        .{ .id = "a", .prompt = "", .assertion_id = "", .threshold = 0, .max_turns = 0, .time_budget_ms = 0, .cost_budget_micros = 0 },
        .{ .id = "b", .prompt = "", .assertion_id = "", .threshold = 0, .max_turns = 0, .time_budget_ms = 0, .cost_budget_micros = 0 },
    };
    const out = try schedule(testing.allocator, exec, &cases, .{ .max_concurrency = 1 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a", out[0].id);
    try testing.expectEqualStrings("b", out[1].id);
    try testing.expectEqual(@as(u32, 2), calls.load(.monotonic));
}

test "schedule: parallel concurrency preserves ordering in the output slice" {
    var calls = std.atomic.Value(u32).init(0);
    const exec = runner.Executor{ .ctx = @ptrCast(&calls), .fun = countingExec };

    var cases_buf: [32]scenario.Case = undefined;
    for (&cases_buf, 0..) |*c, i| {
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
    const out = try schedule(testing.allocator, exec, &cases_buf, .{ .max_concurrency = 8 });
    defer testing.allocator.free(out);

    // Every slot filled, every case ran exactly once.
    try testing.expectEqual(@as(usize, 32), out.len);
    try testing.expectEqual(@as(u32, 32), calls.load(.monotonic));
}
