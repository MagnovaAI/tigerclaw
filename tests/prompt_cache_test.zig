//! Integration tests for prompt-cache planning + the surrounding
//! prompt-builder and tool-selection surfaces.
//!
//! The contract we defend:
//!   * `build` passes through inputs unchanged — providers see
//!     exactly what the caller typed.
//!   * `plan` chooses breakpoints deterministically based only on
//!     its inputs and config.
//!   * Tool selectors filter without heap allocation and respect
//!     the caller's buffer.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const agent = tigerclaw.agent;
const types = tigerclaw.types;

test "prompt: build assembles a ChatRequest the provider can dispatch" {
    const msgs = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const req = agent.prompt_builder.build(.{
        .system = "you are helpful",
        .history = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    try testing.expectEqualStrings("you are helpful", req.system.?);
    try testing.expectEqual(@as(usize, 1), req.messages.len);
    try testing.expectEqualStrings("mock", req.model.provider);
}

test "prompt caching: long system prompt with short history caches system only" {
    const big = "x" ** 2048;
    const r = agent.prompt_caching.plan(big, &.{}, .{});
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(agent.CachePosition.system_end, r.breakpoints[0].position);
}

test "prompt caching: two-breakpoint plan with system and history tail" {
    const big = "x" ** 2048;
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "1" },
        .{ .role = .assistant, .content = "2" },
        .{ .role = .user, .content = "3" },
        .{ .role = .assistant, .content = "4" },
    };
    const r = agent.prompt_caching.plan(big, &msgs, .{ .history_tail_uncached = 2 });
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqual(agent.CachePosition.system_end, r.breakpoints[0].position);
    try testing.expectEqual(@as(usize, 1), r.breakpoints[1].position.message_end);
}

test "prompt caching: max_breakpoints cap is honoured" {
    const big = "x" ** 2048;
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "a" },
        .{ .role = .user, .content = "b" },
    };
    const r = agent.prompt_caching.plan(big, &msgs, .{
        .history_tail_uncached = 1,
        .max_breakpoints = 1,
    });
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(agent.CachePosition.system_end, r.breakpoints[0].position);
}

test "prompt caching: small system prompt is not cached" {
    const r = agent.prompt_caching.plan("short", &.{}, .{});
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "tool selection: allow-all then deny-list narrows the subset" {
    const specs = [_]agent.ToolSpec{
        .{ .name = "a", .description = "" },
        .{ .name = "b", .description = "" },
        .{ .name = "c", .description = "" },
    };

    var allow_all = agent.tool_selection.AllowAll{};
    var out: [3]agent.ToolSpec = undefined;
    const n1 = agent.tool_selection.select(
        allow_all.selector(),
        &specs,
        .{ .user_input = "" },
        &out,
    );
    try testing.expectEqual(@as(usize, 3), n1);

    const deny = [_][]const u8{"b"};
    var dl = agent.tool_selection.DenyList{ .names = &deny };
    var out2: [3]agent.ToolSpec = undefined;
    const n2 = agent.tool_selection.select(
        dl.selector(),
        &specs,
        .{ .user_input = "" },
        &out2,
    );
    try testing.expectEqual(@as(usize, 2), n2);
    try testing.expectEqualStrings("a", out2[0].name);
    try testing.expectEqualStrings("c", out2[1].name);
}

test "trajectory: summary reduces records for diagnostics lifting" {
    var t = agent.Trajectory.init(testing.allocator);
    defer t.deinit();

    try t.push(.{
        .iteration = 1,
        .stop_reason = .tool_use,
        .assistant_bytes = 0,
        .tool_calls = 3,
        .usage = .{ .input = 20, .output = 5 },
    });
    try t.push(.{
        .iteration = 2,
        .stop_reason = .end_turn,
        .assistant_bytes = 11,
        .tool_calls = 0,
        .usage = .{ .input = 3, .output = 8 },
    });

    const s = t.summary();
    try testing.expectEqual(@as(u32, 2), s.iterations);
    try testing.expectEqual(@as(u32, 3), s.total_tool_calls);
    try testing.expectEqual(@as(u32, 11), s.total_assistant_bytes);
    try testing.expectEqual(@as(u32, 23), s.total_usage.input);
    try testing.expectEqual(@as(u32, 13), s.total_usage.output);
}
