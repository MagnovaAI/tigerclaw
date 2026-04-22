//! Anthropic provider.
//!
//! Parses Anthropic's messages streaming format into a `ChatResponse`.
//! HTTP transport is not wired here — the provider takes its SSE bytes
//! from a caller-provided `BytesSource` so tests can drive it with a
//! literal slice and the harness can drive it from a VCR cassette
//! later. Once the HTTP client plumbing lands the `Http` variant will
//! become a real network source without changing the rest of the
//! provider.
//!
//! Event surface covered:
//!
//!   message_start              ignored beyond usage
//!   content_block_start        ignored
//!   content_block_delta        text accumulated
//!   content_block_stop         ignored
//!   message_delta              stop_reason + usage
//!   message_stop               stream ends
//!   error                      surfaces as .refusal with detail message
//!
//! Anything else is silently skipped — the format has grown new event
//! types historically, and we'd rather ignore unknowns than refuse to
//! stream.

const std = @import("std");
const provider_mod = @import("llm_provider");
const transport = @import("llm_transport");
const types = @import("types");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const BytesSource = union(enum) {
    /// The parser consumes these bytes verbatim. Useful for tests and
    /// for cassette-backed replay.
    literal: []const u8,
};

pub const AnthropicProvider = struct {
    source: BytesSource,

    pub fn init(source: BytesSource) AnthropicProvider {
        return .{ .source = source };
    }

    pub fn provider(self: *AnthropicProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
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
        var err_text: ?[]const u8 = null;
        defer if (err_text) |e| allocator.free(e);

        while (try parser.nextEvent(allocator)) |ev| {
            if (std.mem.eql(u8, ev.name, "content_block_delta")) {
                try absorbDelta(allocator, &text, ev.data);
            } else if (std.mem.eql(u8, ev.name, "message_delta")) {
                try absorbMessageDelta(&usage, &stop, ev.data);
            } else if (std.mem.eql(u8, ev.name, "message_start")) {
                try absorbMessageStart(&usage, ev.data);
            } else if (std.mem.eql(u8, ev.name, "error")) {
                stop = .refusal;
                err_text = try absorbError(allocator, ev.data);
            }
            // Unknown events: skip.
        }

        if (err_text) |e| {
            const owned = try allocator.dupe(u8, e);
            text.deinit(allocator);
            return .{
                .text = owned,
                .usage = usage,
                .stop_reason = .refusal,
            };
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

// ---------------------------------------------------------------------------
// Event parsers

fn absorbDelta(
    allocator: std.mem.Allocator,
    out: *std.array_list.Aligned(u8, null),
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    const delta = root.object.get("delta") orelse return;
    const kind = delta.object.get("type") orelse return;
    if (kind != .string) return;
    if (!std.mem.eql(u8, kind.string, "text_delta")) return;
    const text = delta.object.get("text") orelse return;
    if (text != .string) return;
    try out.appendSlice(allocator, text.string);
}

fn absorbMessageDelta(
    usage: *types.TokenUsage,
    stop: *types.StopReason,
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;

    if (root.object.get("delta")) |delta| {
        if (delta.object.get("stop_reason")) |sr| {
            if (sr == .string) {
                if (std.mem.eql(u8, sr.string, "end_turn")) stop.* = .end_turn;
                if (std.mem.eql(u8, sr.string, "max_tokens")) stop.* = .max_tokens;
                if (std.mem.eql(u8, sr.string, "tool_use")) stop.* = .tool_use;
                if (std.mem.eql(u8, sr.string, "stop_sequence")) stop.* = .stop_sequence;
            }
        }
    }
    if (root.object.get("usage")) |u| {
        absorbUsage(usage, u);
    }
}

fn absorbMessageStart(usage: *types.TokenUsage, data: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    const msg = root.object.get("message") orelse return;
    if (msg.object.get("usage")) |u| absorbUsage(usage, u);
}

fn absorbUsage(usage: *types.TokenUsage, u: std.json.Value) void {
    if (u != .object) return;
    if (u.object.get("input_tokens")) |v| if (v == .integer) {
        usage.input = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("output_tokens")) |v| if (v == .integer) {
        usage.output = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("cache_read_input_tokens")) |v| if (v == .integer) {
        usage.cache_read = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("cache_creation_input_tokens")) |v| if (v == .integer) {
        usage.cache_write = @intCast(@max(v.integer, 0));
    };
}

fn absorbError(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const err = parsed.value.object.get("error") orelse return null;
    const msg = err.object.get("message") orelse return null;
    if (msg != .string) return null;
    return try allocator.dupe(u8, msg.string);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeProvider(source: BytesSource) AnthropicProvider {
    return AnthropicProvider.init(source);
}

test "anthropic: assembles text from content_block_delta events" {
    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\", world\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("Hello, world", resp.text.?);
    try testing.expectEqual(@as(u32, 10), resp.usage.input);
    try testing.expectEqual(@as(u32, 3), resp.usage.output);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "anthropic: unknown event types are ignored" {
    const stream =
        "event: ping\ndata: {}\n\n" ++
        "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "event: totally_unknown\ndata: {\"whatever\":1}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("hi", resp.text.?);
}

test "anthropic: error frame surfaces as refusal with detail" {
    const stream =
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Upstream busy\"}}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.refusal, resp.stop_reason);
    try testing.expectEqualStrings("Upstream busy", resp.text.?);
}

test "anthropic: stop_reason variants map correctly" {
    const cases = [_]struct { marker: []const u8, expected: types.StopReason }{
        .{ .marker = "end_turn", .expected = .end_turn },
        .{ .marker = "max_tokens", .expected = .max_tokens },
        .{ .marker = "tool_use", .expected = .tool_use },
        .{ .marker = "stop_sequence", .expected = .stop_sequence },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        const stream = try std.fmt.bufPrint(
            &buf,
            "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}}}\n\n",
            .{c.marker},
        );

        var p = makeProvider(.{ .literal = stream });
        const provider = p.provider();

        const msgs = [_]types.Message{};
        const resp = try provider.chat(testing.allocator, .{
            .messages = &msgs,
            .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
        });
        defer if (resp.text) |t| testing.allocator.free(t);

        try testing.expectEqual(c.expected, resp.stop_reason);
    }
}

test "anthropic: supportsNativeTools is true" {
    var p = makeProvider(.{ .literal = "" });
    const provider = p.provider();
    try testing.expect(provider.supportsNativeTools());
    try testing.expectEqualStrings("anthropic", provider.name());
}
