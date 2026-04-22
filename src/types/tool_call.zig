//! A single tool invocation requested by an assistant turn.

const std = @import("std");

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON-encoded arguments as returned by the provider. The tool
    /// registry decodes this into the tool's typed schema at dispatch.
    arguments_json: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "ToolCall: JSON roundtrip preserves all fields" {
    const tc = ToolCall{
        .id = "call_123",
        .name = "read_file",
        .arguments_json = "{\"path\":\"/tmp/x\"}",
    };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, tc, .{});
    defer testing.allocator.free(s);

    const parsed = try std.json.parseFromSlice(ToolCall, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings(tc.id, parsed.value.id);
    try testing.expectEqualStrings(tc.name, parsed.value.name);
    try testing.expectEqualStrings(tc.arguments_json, parsed.value.arguments_json);
}
