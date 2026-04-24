//! The LLM provider interface.
//!
//! Every backend (mock, anthropic, openai, bedrock, …) exposes a
//! `Provider` value. Callers own the implementing struct — the vtable
//! pointer references it — so returning a `Provider` from a helper that
//! only holds the impl on the stack is a dangling-pointer bug. See
//! docs/ARCHITECTURE.md.

const std = @import("std");
const types = @import("types");

pub const ChatRequest = struct {
    system: ?[]const u8 = null,
    messages: []const types.Message,
    model: types.ModelRef,
    max_output_tokens: ?u32 = null,
    temperature: f32 = 0.7,
    /// Tools the model is allowed to call. Providers that return
    /// `supportsNativeTools() == false` ignore this — the runner is
    /// expected to gate dispatch on capability.
    tools: []const types.Tool = &.{},
};

pub const ChatResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: []const types.ToolCall = &.{},
    usage: types.TokenUsage = .{},
    stop_reason: types.StopReason = .end_turn,

    /// Release every heap-allocated string this response owns. A
    /// centralised helper so callers aren't forced to remember the
    /// growing list of optional slices (`text`, each tool-call's
    /// `id`/`name`/`arguments_json`).
    pub fn deinit(self: ChatResponse, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        for (self.tool_calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        chat: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
        ) anyerror!ChatResponse,
        supportsNativeTools: *const fn (ptr: *anyopaque) bool,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn chat(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        return self.vtable.chat(self.ptr, allocator, request);
    }

    pub fn supportsNativeTools(self: Provider) bool {
        return self.vtable.supportsNativeTools(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const NullImpl = struct {
    fn getName(_: *anyopaque) []const u8 {
        return "null";
    }
    fn doChat(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        return .{};
    }
    fn supportsTools(_: *anyopaque) bool {
        return false;
    }
    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };

    fn provider(self: *NullImpl) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "Provider: vtable dispatch reaches the implementing struct" {
    var impl = NullImpl{};
    const p = impl.provider();

    try testing.expectEqualStrings("null", p.name());
    try testing.expect(!p.supportsNativeTools());

    const messages = [_]types.Message{};
    const resp = try p.chat(testing.allocator, .{
        .messages = &messages,
        .model = .{ .provider = "null", .model = "0" },
    });
    try testing.expect(resp.text == null);
    try testing.expectEqual(@as(usize, 0), resp.tool_calls.len);

    p.deinit();
}
