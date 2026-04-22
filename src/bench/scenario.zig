//! Thin adapter over `scenario.loader.Scenario` with the shape the
//! bench subsystem wants: a description of one measurement target.
//!
//! We deliberately do NOT re-export the loader's `Scenario` as the
//! bench's view. The bench layer cares about a subset (id, prompt,
//! assertion threshold, max turns/time/cost budgets); tying the
//! two directly would propagate any v3 additions into this layer.

const std = @import("std");
const loader = @import("../scenario/loader.zig");

pub const Case = struct {
    id: []const u8,
    prompt: []const u8,
    assertion_id: []const u8,
    threshold: f64,
    max_turns: u32,
    time_budget_ms: u32,
    cost_budget_micros: u64,
};

pub fn fromLoaded(s: loader.Scenario) Case {
    return .{
        .id = s.scenario_id,
        .prompt = s.prompt,
        .assertion_id = s.assertion_id,
        .threshold = s.threshold,
        .max_turns = s.max_turns,
        .time_budget_ms = s.time_budget_ms,
        .cost_budget_micros = s.cost_budget_micros,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Case.fromLoaded: carries the bench-relevant fields" {
    const s = loader.Scenario{
        .scenario_id = "x",
        .prompt = "p",
        .assertion_id = "a",
        .threshold = 0.5,
        .artifacts_glob = "*",
        .max_turns = 7,
    };
    const c = fromLoaded(s);
    try testing.expectEqualStrings("x", c.id);
    try testing.expectEqual(@as(u32, 7), c.max_turns);
    try testing.expectEqual(@as(f64, 0.5), c.threshold);
}
