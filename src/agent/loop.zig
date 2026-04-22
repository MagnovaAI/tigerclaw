//! Iterative react driver.
//!
//! Calls `react.step` until one of:
//!
//!   * the provider returns a stop reason other than `tool_use`,
//!     meaning the assistant considers the turn finished;
//!   * the configured iteration cap is reached, meaning the agent
//!     looped too many times and the runtime halts it.
//!
//! This is still deliberately minimal. Things a later commit will
//! add on top of this same driver:
//!
//!   * budget checks between iterations (Commit 27's Budget is
//!     already there; the CLI will wire it).
//!   * interrupt polling between iterations (Commit 27's
//!     Interrupt, same wiring).
//!   * empty-response and forced-follow-through nudges (v1 has
//!     them; we'll land them with tool-registry context).
//!
//! By keeping the loop this thin, those additions slot in as
//! orthogonal checks in the `while` condition rather than
//! refactors of the control flow.

const std = @import("std");
const types = @import("types");
const llm = @import("../llm/root.zig");
const state_mod = @import("state.zig");
const vtable_mod = @import("vtable.zig");
const react = @import("react.zig");

pub const Config = struct {
    /// Absolute cap on react iterations per turn. Matches the
    /// common-sense default in v1 (1000 was too high for modern
    /// tool use; 32 is generous for most agent flows).
    max_iterations: u32 = 32,
};

pub const TerminationReason = enum {
    /// Provider returned a non-`tool_use` stop reason.
    model_finished,
    /// Iteration cap hit before the model finished.
    iteration_cap,
};

pub const RunOutcome = struct {
    reason: TerminationReason,
    iterations: u32,
    /// Final assistant text the caller probably wants to display.
    /// Points into the state's history; do not free.
    final_text: ?[]const u8,
    /// Aggregated usage across every iteration of this turn.
    usage: types.TokenUsage,
};

/// Run the loop until a terminator trips. `state` is mutated in
/// place; on exit its history contains every message exchanged
/// during the turn.
pub fn run(
    agent_state: *state_mod.AgentState,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
    cfg: Config,
) !RunOutcome {
    agent_state.startNewTurn();

    var total_usage = types.TokenUsage{};
    var last_text: ?[]const u8 = null;

    var iterations: u32 = 0;
    while (iterations < cfg.max_iterations) {
        const out = try react.step(agent_state, provider, executor, model);
        iterations += 1;
        last_text = out.assistant_text orelse last_text;
        total_usage.input +|= @as(u32, @intCast(@min(
            std.math.maxInt(u32) - total_usage.input,
            out.usage.input,
        )));
        total_usage.output +|= @as(u32, @intCast(@min(
            std.math.maxInt(u32) - total_usage.output,
            out.usage.output,
        )));
        total_usage.cache_read +|= @as(u32, @intCast(@min(
            std.math.maxInt(u32) - total_usage.cache_read,
            out.usage.cache_read,
        )));
        total_usage.cache_write +|= @as(u32, @intCast(@min(
            std.math.maxInt(u32) - total_usage.cache_write,
            out.usage.cache_write,
        )));

        if (out.stop_reason != .tool_use) {
            return .{
                .reason = .model_finished,
                .iterations = iterations,
                .final_text = last_text,
                .usage = total_usage,
            };
        }
    }

    return .{
        .reason = .iteration_cap,
        .iterations = iterations,
        .final_text = last_text,
        .usage = total_usage,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "loop.run: single-step turn exits with model_finished" {
    var agent_state = state_mod.AgentState.init(testing.allocator);
    defer agent_state.deinit();
    _ = try agent_state.pushUser("hi");

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "done", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const out = try run(
        &agent_state,
        mock.provider(),
        deny.executor(),
        .{ .provider = "mock", .model = "0" },
        .{},
    );

    try testing.expectEqual(TerminationReason.model_finished, out.reason);
    try testing.expectEqual(@as(u32, 1), out.iterations);
    try testing.expectEqualStrings("done", out.final_text.?);
}

test "loop.run: iteration cap trips when model never stops" {
    var agent_state = state_mod.AgentState.init(testing.allocator);
    defer agent_state.deinit();
    _ = try agent_state.pushUser("forever");

    // Mock returns tool_use forever; with DenyExecutor each call
    // produces an `err` tool result, which feeds right back in.
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &.{.{ .id = "c", .name = "x", .arguments_json = "{}" }} },
    } ** 5;
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const out = try run(
        &agent_state,
        mock.provider(),
        deny.executor(),
        .{ .provider = "mock", .model = "0" },
        .{ .max_iterations = 3 },
    );

    try testing.expectEqual(TerminationReason.iteration_cap, out.reason);
    try testing.expectEqual(@as(u32, 3), out.iterations);
}
