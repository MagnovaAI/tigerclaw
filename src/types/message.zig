//! Canonical `Message` — a single turn in the conversation history.
//!
//! Messages always have structured content: a slice of `ContentBlock`
//! variants (text, tool_use, tool_result). This matches the wire shape
//! every modern LLM API expects (Anthropic Messages, OpenAI chat
//! completions with tool_calls, etc.) and lets the runner thread tool
//! calls and results through history without flattening to strings.
//!
//! Roles are `system`, `user`, `assistant`. There is intentionally no
//! `.tool` role — tool results ride on a `user` message via a
//! `tool_result` content block, mirroring Anthropic's API and how
//! the wire shape the provider expects. The TUI's display-side
//! `Line.Role` keeps a `.tool` category for rendering, which is
//! unrelated to the wire role.

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,

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

/// One block of structured message content. The variants map directly
/// onto Anthropic's content block types (text/tool_use/tool_result).
/// Other providers translate at their boundary.
pub const ContentBlock = union(enum) {
    /// Plain text. Borrowed slice — caller owns the memory.
    text: []const u8,
    /// The assistant invokes a tool. `id` correlates with the matching
    /// `tool_result.tool_use_id` on the next user turn.
    /// `input_json` is already-encoded JSON (so we don't drag a
    /// std.json.Value lifetime through every Message).
    tool_use: ToolUse,
    /// A user turn carrying the result of a previous tool_use.
    tool_result: ToolResultBlock,

    pub const ToolUse = struct {
        id: []const u8,
        name: []const u8,
        input_json: []const u8,
    };

    pub const ToolResultBlock = struct {
        tool_use_id: []const u8,
        /// Plain-text content of the tool result.
        content: []const u8,
        /// True when the tool failed. Anthropic surfaces this to the
        /// model as a hint to retry / pivot rather than treating the
        /// content as authoritative output.
        is_error: bool = false,
    };
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,

    /// Build a comptime-known single-text-block message. The
    /// returned `content` slice points at static `.rodata` and
    /// must NOT be freed. Use this at literal call sites (tests,
    /// fixtures) where the body is comptime-known. For runtime
    /// strings use `allocText`.
    pub fn literal(comptime role: Role, comptime body: []const u8) Message {
        const blocks = &[_]ContentBlock{.{ .text = body }};
        return .{ .role = role, .content = blocks };
    }

    /// Build a single-text-block message backed by an allocator.
    /// Caller frees with `freeOwned`.
    pub fn allocText(
        allocator: std.mem.Allocator,
        role: Role,
        body: []const u8,
    ) !Message {
        const blocks = try allocator.alloc(ContentBlock, 1);
        blocks[0] = .{ .text = try allocator.dupe(u8, body) };
        return .{ .role = role, .content = blocks };
    }

    /// Return the first text block's content, or empty if none.
    /// Convenience accessor for callers that only deal with plain
    /// text turns and want to read content as a string. Tool blocks
    /// are skipped (use a switch on `content[i]` if you need them).
    pub fn flatText(self: Message) []const u8 {
        for (self.content) |b| {
            switch (b) {
                .text => |t| return t,
                else => {},
            }
        }
        return "";
    }

    /// Free a message previously built with one of the `alloc*`
    /// constructors. Walks every content block and frees its inner
    /// slices, then frees the `content` array itself.
    pub fn freeOwned(self: Message, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            switch (block) {
                .text => |t| allocator.free(t),
                .tool_use => |tu| {
                    allocator.free(tu.id);
                    allocator.free(tu.name);
                    allocator.free(tu.input_json);
                },
                .tool_result => |tr| {
                    allocator.free(tr.tool_use_id);
                    allocator.free(tr.content);
                },
            }
        }
        allocator.free(self.content);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Message.allocText: roundtrips role and text" {
    const m = try Message.allocText(testing.allocator, .user, "hello");
    defer m.freeOwned(testing.allocator);

    try testing.expectEqual(Role.user, m.role);
    try testing.expectEqual(@as(usize, 1), m.content.len);
    switch (m.content[0]) {
        .text => |t| try testing.expectEqualStrings("hello", t),
        else => return error.UnexpectedBlockType,
    }
}

test "Message.freeOwned: frees a tool_use block cleanly" {
    const blocks = try testing.allocator.alloc(ContentBlock, 2);
    blocks[0] = .{ .text = try testing.allocator.dupe(u8, "calling") };
    blocks[1] = .{ .tool_use = .{
        .id = try testing.allocator.dupe(u8, "tu1"),
        .name = try testing.allocator.dupe(u8, "get_time"),
        .input_json = try testing.allocator.dupe(u8, "{}"),
    } };
    const m = Message{ .role = .assistant, .content = blocks };
    m.freeOwned(testing.allocator);
}

test "Message.freeOwned: frees a tool_result block cleanly" {
    const blocks = try testing.allocator.alloc(ContentBlock, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try testing.allocator.dupe(u8, "tu1"),
        .content = try testing.allocator.dupe(u8, "2026-04-24T20:00:00Z"),
    } };
    const m = Message{ .role = .user, .content = blocks };
    m.freeOwned(testing.allocator);
}

test "Role: only system/user/assistant are valid wire roles" {
    try testing.expectEqualStrings("system", @tagName(Role.system));
    try testing.expectEqualStrings("user", @tagName(Role.user));
    try testing.expectEqualStrings("assistant", @tagName(Role.assistant));
    try testing.expectEqual(@as(usize, 3), @typeInfo(Role).@"enum".fields.len);
}

test "Role: unknown role rejected" {
    const bad = "\"wizard\"";
    var scanner = std.json.Scanner.initCompleteInput(testing.allocator, bad);
    defer scanner.deinit();
    try testing.expectError(error.UnexpectedToken, Role.jsonParse(testing.allocator, &scanner, .{}));
}

test "Role: tool role no longer exists" {
    try testing.expectEqual(@as(?Role, null), std.meta.stringToEnum(Role, "tool"));
}
