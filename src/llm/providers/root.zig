//! LLM provider implementations.
//!
//! Concrete backends live beside this file as `<name>.zig`. Only `mock`
//! lands with this commit; anthropic/openai/bedrock follow once the
//! transport layer exists.

const std = @import("std");

pub const mock = @import("mock.zig");
pub const anthropic = @import("anthropic.zig");
pub const openai = @import("openai.zig");
pub const bedrock = @import("bedrock.zig");

pub const MockProvider = mock.MockProvider;
pub const MockReply = mock.Reply;
pub const AnthropicProvider = anthropic.AnthropicProvider;
pub const OpenAIProvider = openai.OpenAIProvider;
pub const BedrockProvider = bedrock.BedrockProvider;

test {
    std.testing.refAllDecls(@import("mock.zig"));
    std.testing.refAllDecls(@import("anthropic.zig"));
    std.testing.refAllDecls(@import("openai.zig"));
    std.testing.refAllDecls(@import("bedrock.zig"));
}
