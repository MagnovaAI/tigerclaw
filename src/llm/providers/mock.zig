//! Scriptable in-process provider.
//!
//! Tests build a `MockProvider` whose `chat` returns successive canned
//! `ChatResponse` values from a reply list. Calls past the end of the
//! list return `error.MockExhausted`. Each invocation also increments a
//! call counter so tests can assert how many times they were invoked.
//!
//! Memory contract: the `text` and `tool_calls` slices live as long as
//! the `MockProvider`. `chat` clones the text into the caller's
//! allocator so downstream code that frees the response is safe.

const std = @import("std");
const provider_mod = @import("../provider.zig");
const types = @import("../../types/root.zig");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const Reply = struct {
    text: []const u8,
    tool_calls: []const types.ToolCall = &.{},
    usage: types.TokenUsage = .{},
    stop_reason: types.StopReason = .end_turn,
};

pub const Error = error{
    MockExhausted,
} || std.mem.Allocator.Error;

pub const MockProvider = struct {
    replies: []const Reply,
    cursor: usize = 0,
    call_count: u32 = 0,
    native_tools: bool = false,

    pub fn provider(self: *MockProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *MockProvider) void {
        self.cursor = 0;
        self.call_count = 0;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        self.call_count += 1;

        if (self.cursor >= self.replies.len) return error.MockExhausted;
        const r = self.replies[self.cursor];
        self.cursor += 1;

        return .{
            .text = try allocator.dupe(u8, r.text),
            .tool_calls = r.tool_calls,
            .usage = r.usage,
            .stop_reason = r.stop_reason,
        };
    }

    fn supportsTools(ptr: *anyopaque) bool {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.native_tools;
    }

    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn emptyMessages() [0]types.Message {
    return .{};
}

test "MockProvider: serves replies in order" {
    const replies = [_]Reply{
        .{ .text = "first" },
        .{ .text = "second" },
    };
    var mock = MockProvider{ .replies = &replies };
    const p = mock.provider();

    const msgs = emptyMessages();
    const r1 = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer if (r1.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("first", r1.text.?);

    const r2 = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer if (r2.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("second", r2.text.?);

    try testing.expectEqual(@as(u32, 2), mock.call_count);
}

test "MockProvider: exhaustion returns MockExhausted" {
    const replies = [_]Reply{.{ .text = "only" }};
    var mock = MockProvider{ .replies = &replies };
    const p = mock.provider();

    const msgs = emptyMessages();
    const r1 = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer if (r1.text) |t| testing.allocator.free(t);

    try testing.expectError(
        error.MockExhausted,
        p.chat(testing.allocator, .{
            .messages = &msgs,
            .model = .{ .provider = "mock", .model = "0" },
        }),
    );
}

test "MockProvider: reset rewinds cursor and counter" {
    const replies = [_]Reply{.{ .text = "x" }};
    var mock = MockProvider{ .replies = &replies };
    const p = mock.provider();

    const msgs = emptyMessages();
    const r = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer if (r.text) |t| testing.allocator.free(t);

    mock.reset();
    try testing.expectEqual(@as(u32, 0), mock.call_count);
    try testing.expectEqual(@as(usize, 0), mock.cursor);
}

test "MockProvider: name is 'mock' and native tools is configurable" {
    var mock = MockProvider{ .replies = &[_]Reply{}, .native_tools = true };
    const p = mock.provider();
    try testing.expectEqualStrings("mock", p.name());
    try testing.expect(p.supportsNativeTools());
}
