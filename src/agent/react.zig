//! Single react step: one provider call + tool dispatch.
//!
//! A "step" is one round-trip with the model:
//!
//!   1. Send the current history to the provider.
//!   2. If the response contains an assistant text, record it.
//!   3. If the response contains tool calls, dispatch each through
//!      the `ToolExecutor` and record the results as `role=tool`
//!      messages.
//!
//! The step does *not* decide whether to loop again — that is
//! `loop.zig`'s job. Keeping the step linear makes it easy to
//! test and to hook (a caller can call `step` once per tick if
//! they want a multiplexed event loop rather than a straight
//! call chain).

const std = @import("std");
const types = @import("../types/root.zig");
const llm = @import("../llm/root.zig");
const state_mod = @import("state.zig");
const vtable_mod = @import("vtable.zig");

/// What the step produced. Callers use this to decide whether to
/// keep going.
pub const StepOutcome = struct {
    /// Provider's assistant text, if any. Points into the history
    /// (owned by `state`); do not free.
    assistant_text: ?[]const u8,
    /// Number of tool calls dispatched this step.
    tool_calls: usize,
    /// Provider-reported stop reason. A stop reason of `tool_use`
    /// means the provider wants the tools to run and control
    /// returned to it; anything else terminates the loop.
    stop_reason: types.StopReason,
    /// Token usage for bookkeeping.
    usage: types.TokenUsage,
};

/// Runs one react iteration against the provider. On exit, the
/// state's history has grown by:
///
///   * zero or one `assistant` message (the model's text reply), and
///   * zero or more `tool` messages (one per dispatched tool call).
///
/// Tool-call JSON arguments and names are *not* echoed into the
/// history — only the rendered tool result is. The provider's own
/// tool-use representation is what tracks the call side; the
/// history we keep is the canonical transcript for persistence.
pub fn step(
    agent_state: *state_mod.AgentState,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
) !StepOutcome {
    _ = agent_state.bumpIteration();

    const request = llm.ChatRequest{
        .messages = agent_state.history(),
        .model = model,
    };

    const response = try provider.chat(agent_state.allocator, request);
    // Provider-allocated strings: we either adopt them into the
    // history (via pushAssistant, which duplicates) or free.
    defer if (response.text) |t| agent_state.allocator.free(t);

    var appended_text: ?[]const u8 = null;
    if (response.text) |text| if (text.len > 0) {
        const idx = try agent_state.pushAssistant(text);
        appended_text = agent_state.messages.items[idx].content;
    };

    for (response.tool_calls) |call| {
        const result = try executor.execute(agent_state.allocator, call);
        // The executor allocates call_id + outcome strings out of
        // our allocator; we must free them after rendering into
        // the history.
        defer agent_state.allocator.free(result.call_id);
        const rendered = try renderToolResult(agent_state.allocator, result);
        defer agent_state.allocator.free(rendered);
        _ = try agent_state.pushTool(rendered);
    }

    return .{
        .assistant_text = appended_text,
        .tool_calls = response.tool_calls.len,
        .stop_reason = response.stop_reason,
        .usage = response.usage,
    };
}

/// Serialise a `ToolResult` into the line format the next provider
/// call will see. Keeping this format tiny and explicit avoids
/// depending on std.json for something whose shape we control.
fn renderToolResult(allocator: std.mem.Allocator, r: types.ToolResult) ![]u8 {
    return switch (r.outcome) {
        .ok => |payload| blk: {
            defer allocator.free(payload);
            break :blk try std.fmt.allocPrint(allocator, "ok:{s}", .{payload});
        },
        .err => |b| blk: {
            defer allocator.free(b.detail);
            break :blk try std.fmt.allocPrint(allocator, "err[{s}]:{s}", .{ b.id, b.detail });
        },
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "step: assistant text is appended and reported" {
    var agent_state = state_mod.AgentState.init(testing.allocator);
    defer agent_state.deinit();
    _ = try agent_state.pushUser("hi");

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "hello", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const out = try step(
        &agent_state,
        mock.provider(),
        deny.executor(),
        .{ .provider = "mock", .model = "0" },
    );

    try testing.expectEqualStrings("hello", out.assistant_text.?);
    try testing.expectEqual(@as(usize, 0), out.tool_calls);
    try testing.expectEqual(types.StopReason.end_turn, out.stop_reason);
    try testing.expectEqual(@as(usize, 2), agent_state.len());
}

test "step: empty-text response does not pollute history with a blank message" {
    var agent_state = state_mod.AgentState.init(testing.allocator);
    defer agent_state.deinit();
    _ = try agent_state.pushUser("hi");

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const out = try step(
        &agent_state,
        mock.provider(),
        deny.executor(),
        .{ .provider = "mock", .model = "0" },
    );

    try testing.expect(out.assistant_text == null);
    try testing.expectEqual(@as(usize, 1), agent_state.len());
}
