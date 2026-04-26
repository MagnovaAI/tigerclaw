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
    /// Cooperative cancellation flag. When non-null, the provider's
    /// streaming reader checks `cancel_token.load(.acquire)` between
    /// events; on `true` the call returns the partial response
    /// accumulated so far with `stop_reason = .cancelled`. Caller
    /// owns the atomic and must keep it alive for the duration of
    /// the request. Null means cancellation is not wired (legacy
    /// callers, tests).
    cancel_token: ?*std.atomic.Value(bool) = null,
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

/// Incremental-delta callback used by `Provider.chatStream`. Fires
/// once per fragment of assistant text as the provider decodes its
/// upstream stream; the slice is borrowed for the duration of the
/// call and must be copied if the sink needs to retain it. `ctx`
/// carries opaque caller state (typically the gateway's SSE writer).
pub const TokenSink = *const fn (ctx: ?*anyopaque, token: []const u8) void;

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
        /// Optional streaming variant. Backends that decode provider
        /// SSE natively (e.g. Anthropic) set this so every text delta
        /// fires `sink(ctx, fragment)` as soon as it arrives. Backends
        /// that don't leave it null; `Provider.chatStream` falls back
        /// to `chat` + a single final-text invocation of the sink.
        chatStream: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: ChatRequest,
            sink: TokenSink,
            sink_ctx: ?*anyopaque,
        ) anyerror!ChatResponse = null,
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

    /// Stream-aware chat. When the backend supplies `chatStream`,
    /// fragments are forwarded to `sink` as they decode. Otherwise we
    /// fall back to a full `chat` and fire the sink once with the
    /// finished text — simpler callers don't need to branch on
    /// whether streaming is live.
    pub fn chatStream(
        self: Provider,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        sink: TokenSink,
        sink_ctx: ?*anyopaque,
    ) anyerror!ChatResponse {
        if (self.vtable.chatStream) |stream_fn| {
            return stream_fn(self.ptr, allocator, request, sink, sink_ctx);
        }
        const resp = try self.vtable.chat(self.ptr, allocator, request);
        if (resp.text) |t| if (t.len > 0) sink(sink_ctx, t);
        return resp;
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

/// Captures sink invocations for the streaming-fallback tests. The
/// sink contract promises caller-allocated `ctx` that outlives the
/// call; concatenating into a fixed buffer is the simplest way to
/// assert order + content without chasing allocator lifetimes.
const FixedSink = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn append(ctx: ?*anyopaque, fragment: []const u8) void {
        const self: *FixedSink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const room = self.buf.len - self.len;
        const take = @min(fragment.len, room);
        @memcpy(self.buf[self.len .. self.len + take], fragment[0..take]);
        self.len += take;
    }
};

/// Impl that returns a concrete text slice from `chat` with no
/// `chatStream` override — exercises the fallback path in
/// `Provider.chatStream`.
const TextImpl = struct {
    fn getName(_: *anyopaque) []const u8 {
        return "text";
    }
    fn doChat(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        return .{ .text = try allocator.dupe(u8, "hello world") };
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

    fn provider(self: *TextImpl) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "Provider.chatStream: falls back to single sink call when chatStream is null" {
    var impl = TextImpl{};
    const p = impl.provider();

    var sink = FixedSink{};
    const messages = [_]types.Message{};
    const resp = try p.chatStream(
        testing.allocator,
        .{ .messages = &messages, .model = .{ .provider = "text", .model = "0" } },
        FixedSink.append,
        &sink,
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings("hello world", sink.buf[0..sink.len]);
    try testing.expectEqualStrings("hello world", resp.text.?);
}

/// Impl that *does* provide `chatStream` and fires the sink three
/// times. Verifies the vtable forwards to the stream function rather
/// than falling back to `chat`.
const StreamImpl = struct {
    fn getName(_: *anyopaque) []const u8 {
        return "stream";
    }
    fn doChat(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        // Should not be called when `chatStream` is set.
        return .{};
    }
    fn doChatStream(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
        sink: TokenSink,
        sink_ctx: ?*anyopaque,
    ) anyerror!ChatResponse {
        sink(sink_ctx, "one");
        sink(sink_ctx, "two");
        sink(sink_ctx, "three");
        return .{ .text = try allocator.dupe(u8, "onetwothree") };
    }
    fn supportsTools(_: *anyopaque) bool {
        return false;
    }
    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .chatStream = doChatStream,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };

    fn provider(self: *StreamImpl) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "Provider.chatStream: forwards to the stream fn when provided" {
    var impl = StreamImpl{};
    const p = impl.provider();

    var sink = FixedSink{};
    const messages = [_]types.Message{};
    const resp = try p.chatStream(
        testing.allocator,
        .{ .messages = &messages, .model = .{ .provider = "stream", .model = "0" } },
        FixedSink.append,
        &sink,
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), sink.calls);
    try testing.expectEqualStrings("onetwothree", sink.buf[0..sink.len]);
    try testing.expectEqualStrings("onetwothree", resp.text.?);
}
