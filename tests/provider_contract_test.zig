//! Provider contract suite.
//!
//! Every concrete provider (mock now; anthropic/openai/bedrock later)
//! must pass these invariants. The suite takes a live `Provider`
//! alongside a tiny `Hooks` struct describing how the test should
//! prepare for each step: reset the provider, obtain an expected
//! response, etc.
//!
//! A second implementation that wants to plug in copies the harness
//! block at the bottom of this file: set up the impl, hand a
//! `Provider` value to `runAll`, and call it done.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const llm = tigerclaw.llm;

const testing = std.testing;

pub const Hooks = struct {
    /// Put the backend into a known state between tests.
    reset: *const fn () void,
    /// First-reply text. The suite asserts this exact string is returned.
    first_reply_text: []const u8,
    /// Name the backend advertises. Must be non-empty.
    backend_name: []const u8,
};

pub fn runAll(provider: llm.Provider, hooks: Hooks) !void {
    try assertName(provider, hooks);
    try assertFirstCallRoundtrips(provider, hooks);
    try assertTextIsCallerOwned(provider, hooks);
}

fn assertName(provider: llm.Provider, hooks: Hooks) !void {
    hooks.reset();
    try testing.expect(provider.name().len > 0);
    try testing.expectEqualStrings(hooks.backend_name, provider.name());
}

fn assertFirstCallRoundtrips(provider: llm.Provider, hooks: Hooks) !void {
    hooks.reset();
    const msgs = [_]tigerclaw.types.Message{tigerclaw.types.Message.literal(.user, "hi")};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = hooks.backend_name, .model = "0" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expect(resp.text != null);
    try testing.expectEqualStrings(hooks.first_reply_text, resp.text.?);
}

fn assertTextIsCallerOwned(provider: llm.Provider, hooks: Hooks) !void {
    // The contract says callers own the returned text. We verify by
    // freeing from the caller allocator without a double-free.
    hooks.reset();
    const msgs = [_]tigerclaw.types.Message{tigerclaw.types.Message.literal(.user, "hi")};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = hooks.backend_name, .model = "0" },
    });
    if (resp.text) |t| testing.allocator.free(t);
}

// ---------------------------------------------------------------------------
// Mock provider harness: prove the contract runs against the one backend
// shipped today.

var _mock: llm.MockProvider = .{ .replies = &_mock_replies };

const _mock_replies = [_]llm.providers.mock.Reply{
    .{ .text = "contract-reply" },
    .{ .text = "contract-reply" },
    .{ .text = "contract-reply" },
};

fn mockReset() void {
    _mock.reset();
}

test "contract: MockProvider satisfies the provider invariants" {
    try runAll(_mock.provider(), .{
        .reset = mockReset,
        .first_reply_text = "contract-reply",
        .backend_name = "mock",
    });
}

// ---------------------------------------------------------------------------
// Anthropic provider harness: same contract, different backend.

const _anthropic_stream =
    "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"contract-reply\"}}\n\n" ++
    "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

var _anthropic: llm.providers.AnthropicProvider = undefined;

fn anthropicReset() void {
    _anthropic = llm.providers.AnthropicProvider.init(.{ .literal = _anthropic_stream });
}

test "contract: AnthropicProvider satisfies the provider invariants" {
    anthropicReset();
    try runAll(_anthropic.provider(), .{
        .reset = anthropicReset,
        .first_reply_text = "contract-reply",
        .backend_name = "anthropic",
    });
}

// ---------------------------------------------------------------------------
// OpenAI provider harness.

const _openai_stream =
    "data: {\"choices\":[{\"delta\":{\"content\":\"contract-reply\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

var _openai: llm.providers.OpenAIProvider = undefined;

fn openaiReset() void {
    _openai = llm.providers.OpenAIProvider.init(.{ .literal = _openai_stream });
}

test "contract: OpenAIProvider satisfies the provider invariants" {
    openaiReset();
    try runAll(_openai.provider(), .{
        .reset = openaiReset,
        .first_reply_text = "contract-reply",
        .backend_name = "openai",
    });
}

// ---------------------------------------------------------------------------
// Bedrock provider harness.

const _bedrock_chunks = [_][]const u8{"contract-reply"};

var _bedrock: llm.providers.BedrockProvider = undefined;

fn bedrockReset() void {
    _bedrock = llm.providers.BedrockProvider.init(.{ .text_chunks = &_bedrock_chunks });
}

test "contract: BedrockProvider satisfies the provider invariants" {
    bedrockReset();
    try runAll(_bedrock.provider(), .{
        .reset = bedrockReset,
        .first_reply_text = "contract-reply",
        .backend_name = "bedrock",
    });
}
