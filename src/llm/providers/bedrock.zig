//! Bedrock provider (stub).
//!
//! Amazon Bedrock's `invoke_model_with_response_stream` endpoint uses a
//! binary framing (`application/vnd.amazon.eventstream`) rather than
//! SSE. That parser is its own substantial piece of work and lands once
//! we have a use case pinning the exact Anthropic-on-Bedrock shape the
//! harness will target.
//!
//! For now this file satisfies the provider contract with a literal
//! JSON-lines source so downstream code that wants to branch on
//! `ModelRef{ .provider = "bedrock" }` can compile and run against a
//! fixture. Once the real parser lands the line-oriented source will
//! be replaced by the binary-framing reader; the public vtable stays
//! the same.

const std = @import("std");
const provider_mod = @import("../provider.zig");
const types = @import("../../types/root.zig");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

/// Each entry in `text_chunks` is a partial completion; they are
/// concatenated into the returned `ChatResponse.text`.
pub const Script = struct {
    text_chunks: []const []const u8 = &.{},
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    stop_reason: types.StopReason = .end_turn,
};

pub const BedrockProvider = struct {
    script: Script,

    pub fn init(script: Script) BedrockProvider {
        return .{ .script = script };
    }

    pub fn provider(self: *BedrockProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "bedrock";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *BedrockProvider = @ptrCast(@alignCast(ptr));

        var text: std.array_list.Aligned(u8, null) = .empty;
        errdefer text.deinit(allocator);
        for (self.script.text_chunks) |chunk| {
            try text.appendSlice(allocator, chunk);
        }

        return .{
            .text = try text.toOwnedSlice(allocator),
            .usage = .{
                .input = self.script.input_tokens,
                .output = self.script.output_tokens,
            },
            .stop_reason = self.script.stop_reason,
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

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "bedrock: assembles chunks and surfaces usage" {
    var p = BedrockProvider.init(.{
        .text_chunks = &.{ "part-1 ", "part-2" },
        .input_tokens = 30,
        .output_tokens = 7,
    });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "bedrock", .model = "anthropic.claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("part-1 part-2", resp.text.?);
    try testing.expectEqual(@as(u32, 30), resp.usage.input);
    try testing.expectEqual(@as(u32, 7), resp.usage.output);
}

test "bedrock: empty script still returns a valid response" {
    var p = BedrockProvider.init(.{});
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "bedrock", .model = "anthropic.claude-haiku-4-5-20251001" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("", resp.text.?);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "bedrock: name and native tools" {
    var p = BedrockProvider.init(.{});
    const provider = p.provider();
    try testing.expectEqualStrings("bedrock", provider.name());
    try testing.expect(provider.supportsNativeTools());
}
