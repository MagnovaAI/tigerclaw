//! Canonical `Message` — a single turn in the conversation history.

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonStringify(self: Role, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Role {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(Role, s)) |role| return role;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Message: JSON roundtrip preserves role and content" {
    const msg = Message{ .role = .user, .content = "hello" };

    const json_bytes = try std.json.Stringify.valueAlloc(testing.allocator, msg, .{});
    defer testing.allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(Message, testing.allocator, json_bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(Role.user, parsed.value.role);
    try testing.expectEqualStrings("hello", parsed.value.content);
}

test "Message: unknown role rejected" {
    const bad = "{\"role\":\"wizard\",\"content\":\"x\"}";
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Message, testing.allocator, bad, .{}),
    );
}

test "Role: tag name is stable" {
    try testing.expectEqualStrings("system", @tagName(Role.system));
    try testing.expectEqualStrings("user", @tagName(Role.user));
    try testing.expectEqualStrings("assistant", @tagName(Role.assistant));
    try testing.expectEqualStrings("tool", @tagName(Role.tool));
}
