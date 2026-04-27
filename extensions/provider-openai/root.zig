//! OpenAI provider.
//!
//! Parses OpenAI's chat.completions streaming format. OpenAI's SSE is
//! simpler than Anthropic's: every event is the default ("message")
//! type with a single `data:` payload, and the stream terminates with
//! `data: [DONE]`. Successful events are JSON objects whose
//! `choices[0].delta.content` carries a text chunk.
//!
//! As with `anthropic.zig`, the provider takes its bytes from a caller-
//! supplied `BytesSource`; real HTTP wiring arrives with the routing /
//! reliability layer.

const std = @import("std");
const provider_mod = @import("llm_provider");
const transport = @import("llm_transport");
const types = @import("types");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const BytesSource = union(enum) {
    literal: []const u8,
};

pub const OpenAIProvider = struct {
    source: BytesSource,

    pub fn init(source: BytesSource) OpenAIProvider {
        return .{ .source = source };
    }

    pub fn provider(self: *OpenAIProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openai";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        const bytes = switch (self.source) {
            .literal => |b| b,
        };

        var parser = transport.sse.Parser.init();
        defer parser.deinit(allocator);
        try parser.feed(allocator, bytes);

        var text: std.array_list.Aligned(u8, null) = .empty;
        errdefer text.deinit(allocator);

        var usage = types.TokenUsage{};
        var stop: types.StopReason = .end_turn;

        while (try parser.nextEvent(allocator)) |ev| {
            if (std.mem.eql(u8, ev.data, "[DONE]")) break;
            try absorbChunk(allocator, &text, &usage, &stop, ev.data);
        }

        return .{
            .text = try text.toOwnedSlice(allocator),
            .usage = usage,
            .stop_reason = stop,
        };
    }

    fn supportsTools(_: *anyopaque) bool {
        return true;
    }

    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
};

fn absorbChunk(
    allocator: std.mem.Allocator,
    out: *std.array_list.Aligned(u8, null),
    usage: *types.TokenUsage,
    stop: *types.StopReason,
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first.object.get("delta")) |delta| {
                if (delta.object.get("content")) |c| {
                    if (c == .string) try out.appendSlice(allocator, c.string);
                }
            }
            if (first.object.get("finish_reason")) |fr| {
                if (fr == .string) stop.* = mapFinishReason(fr.string);
            }
        }
    }
    if (root.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| if (v == .integer) {
                usage.input = @intCast(@max(v.integer, 0));
            };
            if (u.object.get("completion_tokens")) |v| if (v == .integer) {
                usage.output = @intCast(@max(v.integer, 0));
            };
        }
    }
}

fn mapFinishReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .end_turn;
    if (std.mem.eql(u8, reason, "length")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .refusal;
    return .end_turn;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "openai: assembles content across chunks" {
    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\", world\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";

    var p = OpenAIProvider.init(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "openai", .model = "gpt-4o" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("Hello, world", resp.text.?);
    try testing.expectEqual(@as(u32, 5), resp.usage.input);
    try testing.expectEqual(@as(u32, 3), resp.usage.output);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "openai: finish_reason variants map" {
    const cases = [_]struct { reason: []const u8, expected: types.StopReason }{
        .{ .reason = "stop", .expected = .end_turn },
        .{ .reason = "length", .expected = .max_tokens },
        .{ .reason = "tool_calls", .expected = .tool_use },
        .{ .reason = "content_filter", .expected = .refusal },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        const stream = try std.fmt.bufPrint(
            &buf,
            "data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\ndata: [DONE]\n\n",
            .{c.reason},
        );
        var p = OpenAIProvider.init(.{ .literal = stream });
        const provider = p.provider();

        const msgs = [_]types.Message{};
        const resp = try provider.chat(testing.allocator, .{
            .messages = &msgs,
            .model = .{ .provider = "openai", .model = "gpt-4o" },
        });
        defer if (resp.text) |t| testing.allocator.free(t);
        try testing.expectEqual(c.expected, resp.stop_reason);
    }
}

test "openai: stream stops at [DONE]" {
    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"kept\"}}]}\n\n" ++
        "data: [DONE]\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"should not appear\"}}]}\n\n";

    var p = OpenAIProvider.init(.{ .literal = stream });
    const provider = p.provider();
    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "openai", .model = "gpt-4o" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("kept", resp.text.?);
}

test "openai: name and native tools" {
    var p = OpenAIProvider.init(.{ .literal = "" });
    const provider = p.provider();
    try testing.expectEqualStrings("openai", provider.name());
    try testing.expect(provider.supportsNativeTools());
}
