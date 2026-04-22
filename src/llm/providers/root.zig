//! LLM provider implementations.
//!
//! `mock` is a built-in test double that always compiles. Real provider
//! backends live under `extensions/<name>/root.zig` and are wired in as
//! separate named build modules gated by `-Dextensions=`. The comptime
//! branches below replace each provider's surface with `void` when its
//! extension is disabled, so the binary contains only the providers
//! requested at build time.

const std = @import("std");
const build_options = @import("build_options");

pub const mock = @import("mock.zig");
pub const MockProvider = mock.MockProvider;
pub const MockReply = mock.Reply;

pub const anthropic = if (build_options.enable_anthropic) @import("provider_anthropic") else struct {};
pub const openai = if (build_options.enable_openai) @import("provider_openai") else struct {};
pub const bedrock = if (build_options.enable_bedrock) @import("provider_bedrock") else struct {};

pub const AnthropicProvider = if (build_options.enable_anthropic) anthropic.AnthropicProvider else void;
pub const OpenAIProvider = if (build_options.enable_openai) openai.OpenAIProvider else void;
pub const BedrockProvider = if (build_options.enable_bedrock) bedrock.BedrockProvider else void;

test {
    std.testing.refAllDecls(@import("mock.zig"));
    if (build_options.enable_anthropic) std.testing.refAllDecls(@import("provider_anthropic"));
    if (build_options.enable_openai) std.testing.refAllDecls(@import("provider_openai"));
    if (build_options.enable_bedrock) std.testing.refAllDecls(@import("provider_bedrock"));
}
