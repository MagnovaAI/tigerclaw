//! A single response from an LLM provider.

const std = @import("std");
const TokenUsage = @import("token_usage.zig").TokenUsage;
const ToolCall = @import("tool_call.zig").ToolCall;

pub const StopReason = enum {
    end_turn,
    max_tokens,
    tool_use,
    stop_sequence,
    refusal,

    pub fn jsonStringify(self: StopReason, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StopReason {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(StopReason, s)) |r| return r;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const LlmResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: TokenUsage = .{},
    stop_reason: StopReason = .end_turn,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "LlmResponse: JSON roundtrip preserves text, usage, and stop reason" {
    const r = LlmResponse{
        .text = "hello world",
        .usage = .{ .input = 10, .output = 3 },
        .stop_reason = .end_turn,
    };

    const s = try std.json.Stringify.valueAlloc(testing.allocator, r, .{});
    defer testing.allocator.free(s);

    const parsed = try std.json.parseFromSlice(LlmResponse, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("hello world", parsed.value.text.?);
    try testing.expectEqual(@as(u32, 10), parsed.value.usage.input);
    try testing.expectEqual(@as(u32, 3), parsed.value.usage.output);
    try testing.expectEqual(StopReason.end_turn, parsed.value.stop_reason);
}

test "LlmResponse: unknown stop_reason rejected" {
    const bad = "{\"text\":null,\"tool_calls\":[],\"usage\":{},\"stop_reason\":\"bogus\"}";
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(LlmResponse, testing.allocator, bad, .{}),
    );
}

test "LlmResponse: defaults are nil/empty/end_turn" {
    const r = LlmResponse{};
    try testing.expect(r.text == null);
    try testing.expectEqual(@as(usize, 0), r.tool_calls.len);
    try testing.expectEqual(StopReason.end_turn, r.stop_reason);
}
