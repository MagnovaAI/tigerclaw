//! Integration tests for the react loop.
//!
//! These exercise the whole agent subsystem end-to-end through
//! the public facade: scripted tool calls, multi-step
//! conversations, iteration caps, and that the transcript the
//! runtime hands to persistence is internally consistent.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const agent = tigerclaw.agent;
const llm = tigerclaw.llm;
const types = tigerclaw.types;

/// Scripted executor that returns canned results by call index.
/// Each entry becomes the outcome for the Nth dispatched call.
const ScriptedExecutor = struct {
    oks: []const []const u8,
    cursor: usize = 0,

    fn execute(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        call: types.ToolCall,
    ) anyerror!types.ToolResult {
        const self: *ScriptedExecutor = @ptrCast(@alignCast(ptr));
        if (self.cursor >= self.oks.len) return error.ScriptExhausted;
        const payload = self.oks[self.cursor];
        self.cursor += 1;

        const id_copy = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id_copy);
        const out_copy = try allocator.dupe(u8, payload);
        return .{
            .call_id = id_copy,
            .outcome = .{ .ok = out_copy },
        };
    }

    fn executor(self: *ScriptedExecutor) agent.ToolExecutor {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }
};

test "react loop: single-turn model-finished conversation" {
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "answer", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = agent.DenyExecutor{};

    var a = agent.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = deny.executor(),
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer a.deinit();

    const out = try a.runTurn("q");
    try testing.expectEqual(agent.TerminationReason.model_finished, out.reason);
    try testing.expectEqualStrings("answer", out.final_text.?);
    try testing.expectEqual(@as(usize, 2), a.history().len);
}

test "react loop: tool use then final answer closes in two iterations" {
    // Turn 1: model asks for tool `x` and returns no text.
    // Turn 2 (after tool result feeds in): model returns final text.
    const tc = [_]types.ToolCall{.{ .id = "c1", .name = "x", .arguments_json = "{}" }};
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &tc },
        .{ .text = "final", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };

    const oks = [_][]const u8{"tool-result"};
    var scripted = ScriptedExecutor{ .oks = &oks };

    var a = agent.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = scripted.executor(),
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer a.deinit();

    const out = try a.runTurn("q");
    try testing.expectEqual(agent.TerminationReason.model_finished, out.reason);
    try testing.expectEqual(@as(u32, 2), out.iterations);
    try testing.expectEqualStrings("final", out.final_text.?);

    // Transcript: user, tool-result, assistant-final. The first
    // iteration produced no assistant text (empty), so only the
    // tool message and the final assistant text were appended.
    const h = a.history();
    try testing.expectEqual(@as(usize, 3), h.len);
    try testing.expectEqual(types.Role.user, h[0].role);
    try testing.expectEqualStrings("q", h[0].content);
    try testing.expectEqual(types.Role.tool, h[1].role);
    try testing.expectEqualStrings("ok:tool-result", h[1].content);
    try testing.expectEqual(types.Role.assistant, h[2].role);
    try testing.expectEqualStrings("final", h[2].content);
}

test "react loop: iteration cap halts a runaway model" {
    const tc = [_]types.ToolCall{.{ .id = "c", .name = "loop", .arguments_json = "{}" }};
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &tc },
    } ** 10;
    var mock = llm.MockProvider{ .replies = &replies };

    const oks = [_][]const u8{ "r", "r", "r", "r", "r", "r", "r", "r", "r", "r" };
    var scripted = ScriptedExecutor{ .oks = &oks };

    var a = agent.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = scripted.executor(),
        .model = .{ .provider = "mock", .model = "0" },
        .loop = .{ .max_iterations = 4 },
    });
    defer a.deinit();

    const out = try a.runTurn("go");
    try testing.expectEqual(agent.TerminationReason.iteration_cap, out.reason);
    try testing.expectEqual(@as(u32, 4), out.iterations);
}

test "react loop: usage accumulates across iterations" {
    const tc = [_]types.ToolCall{.{ .id = "c", .name = "x", .arguments_json = "{}" }};
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &tc, .usage = .{ .input = 10, .output = 5 } },
        .{ .text = "done", .stop_reason = .end_turn, .usage = .{ .input = 3, .output = 7 } },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    const oks = [_][]const u8{"x"};
    var scripted = ScriptedExecutor{ .oks = &oks };

    var a = agent.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = scripted.executor(),
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer a.deinit();

    const out = try a.runTurn("q");
    try testing.expectEqual(@as(u32, 13), out.usage.input);
    try testing.expectEqual(@as(u32, 12), out.usage.output);
}

test "react loop: multiple tool calls in one turn all land in the transcript" {
    const tc = [_]types.ToolCall{
        .{ .id = "a", .name = "t", .arguments_json = "{}" },
        .{ .id = "b", .name = "t", .arguments_json = "{}" },
    };
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &tc },
        .{ .text = "ok", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    const oks = [_][]const u8{ "first", "second" };
    var scripted = ScriptedExecutor{ .oks = &oks };

    var a = agent.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = scripted.executor(),
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer a.deinit();

    _ = try a.runTurn("q");
    const h = a.history();
    // user, tool(first), tool(second), assistant(ok)
    try testing.expectEqual(@as(usize, 4), h.len);
    try testing.expectEqualStrings("ok:first", h[1].content);
    try testing.expectEqualStrings("ok:second", h[2].content);
}
