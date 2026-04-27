//! Scriptable in-process provider.
//!
//! Tests build a `MockProvider` whose `chat` returns successive canned
//! `ChatResponse` values from a reply list. Calls past the end of the
//! list return `error.MockExhausted`. Each invocation also increments a
//! call counter so tests can assert how many times they were invoked.
//!
//! Memory contract: replies are static fixtures, but `chat` returns an
//! owning `ChatResponse` whose text and tool-call fields are cloned into
//! the caller's allocator. Downstream code can always call
//! `ChatResponse.deinit`.

const std = @import("std");
const provider_mod = @import("llm_provider");
const types = @import("types");

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

        const text = try allocator.dupe(u8, r.text);
        errdefer allocator.free(text);
        const tool_calls = try cloneToolCalls(allocator, r.tool_calls);
        return .{
            .text = text,
            .tool_calls = tool_calls,
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

fn cloneToolCalls(
    allocator: std.mem.Allocator,
    calls: []const types.ToolCall,
) std.mem.Allocator.Error![]const types.ToolCall {
    if (calls.len == 0) return &.{};

    const out = try allocator.alloc(types.ToolCall, calls.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer freeToolCalls(allocator, out[0..initialized]);

    for (calls, 0..) |call, i| {
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments_json = try allocator.dupe(u8, call.arguments_json);

        out[i] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments_json,
        };
        initialized += 1;
    }

    return out;
}

fn freeToolCalls(allocator: std.mem.Allocator, calls: []const types.ToolCall) void {
    for (calls) |call| {
        allocator.free(call.id);
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
}

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
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("first", r1.text.?);

    const r2 = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer r2.deinit(testing.allocator);
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
    defer r1.deinit(testing.allocator);

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
    defer r.deinit(testing.allocator);

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

test "MockProvider: clones tool calls into the response allocator" {
    const calls = [_]types.ToolCall{
        .{ .id = "c1", .name = "read", .arguments_json = "{\"path\":\"x\"}" },
    };
    const replies = [_]Reply{
        .{ .text = "", .tool_calls = &calls, .stop_reason = .tool_use },
    };
    var mock = MockProvider{ .replies = &replies };
    const p = mock.provider();

    const msgs = emptyMessages();
    const r = try p.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer r.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), r.tool_calls.len);
    try testing.expectEqualStrings("c1", r.tool_calls[0].id);
    try testing.expect(r.tool_calls.ptr != calls[0..].ptr);
}
