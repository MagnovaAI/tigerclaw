//! Single-case runner.
//!
//! `runCase` takes a `Case`, an executor callback, and an allocator
//! and produces a `CaseMetric`. The callback owns the actual agent
//! wiring — the bench layer is deliberately ignorant of which
//! provider or tools ran. That boundary keeps the bench runner
//! replayable against mock, scripted, or real workloads by swapping
//! the callback.

const std = @import("std");
const scenario = @import("scenario.zig");
const metrics = @import("metrics.zig");

/// Callback signature: given a prompt, return the (score, passed,
/// turns, cost) tuple. Caller-allocated; must not borrow from
/// stack-local state that outlives the call.
pub const Outcome = struct {
    score: f64,
    turns: u32,
    cost_micros: u64,
    outcome_tag: []const u8 = "ok",
};

pub const ExecuteFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    case: scenario.Case,
) anyerror!Outcome;

pub const Executor = struct {
    ctx: *anyopaque,
    fun: ExecuteFn,

    pub fn run(
        self: Executor,
        allocator: std.mem.Allocator,
        case: scenario.Case,
    ) !Outcome {
        return self.fun(self.ctx, allocator, case);
    }
};

pub fn runCase(
    allocator: std.mem.Allocator,
    executor: Executor,
    case: scenario.Case,
) !metrics.CaseMetric {
    const out = executor.run(allocator, case) catch |err| {
        return .{
            .id = case.id,
            .passed = false,
            .outcome = @errorName(err),
        };
    };

    return .{
        .id = case.id,
        .passed = out.score >= case.threshold,
        .score = out.score,
        .turns = out.turns,
        .cost_micros = out.cost_micros,
        .outcome = out.outcome_tag,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn fixedExec(ctx: *anyopaque, _: std.mem.Allocator, _: scenario.Case) anyerror!Outcome {
    const score_ptr: *const f64 = @ptrCast(@alignCast(ctx));
    return .{ .score = score_ptr.*, .turns = 1, .cost_micros = 10 };
}

test "runCase: score above threshold passes" {
    var score: f64 = 0.95;
    const exec = Executor{ .ctx = @ptrCast(&score), .fun = fixedExec };
    const m = try runCase(testing.allocator, exec, .{
        .id = "c",
        .prompt = "",
        .assertion_id = "eq",
        .threshold = 0.9,
        .max_turns = 0,
        .time_budget_ms = 0,
        .cost_budget_micros = 0,
    });
    try testing.expect(m.passed);
    try testing.expectEqual(@as(?f64, 0.95), m.score);
}

test "runCase: score below threshold fails" {
    var score: f64 = 0.5;
    const exec = Executor{ .ctx = @ptrCast(&score), .fun = fixedExec };
    const m = try runCase(testing.allocator, exec, .{
        .id = "c",
        .prompt = "",
        .assertion_id = "eq",
        .threshold = 0.9,
        .max_turns = 0,
        .time_budget_ms = 0,
        .cost_budget_micros = 0,
    });
    try testing.expect(!m.passed);
}
