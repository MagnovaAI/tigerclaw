//! LLM stack: provider interface, thin client facade, token estimator.
//!
//! Concrete providers (mock, anthropic, openai, bedrock) and the
//! transport / routing / reliability layers land in follow-up commits.

const std = @import("std");

pub const provider = @import("provider.zig");
pub const client = @import("client.zig");
pub const token_estimator = @import("token_estimator.zig");
pub const providers = @import("providers/root.zig");
pub const transport = @import("transport/root.zig");
pub const routing = @import("routing/root.zig");

pub const Provider = provider.Provider;
pub const ChatRequest = provider.ChatRequest;
pub const ChatResponse = provider.ChatResponse;
pub const Client = client.Client;
pub const MockProvider = providers.MockProvider;
pub const Router = routing.Router;

test {
    std.testing.refAllDecls(@import("provider.zig"));
    std.testing.refAllDecls(@import("client.zig"));
    std.testing.refAllDecls(@import("token_estimator.zig"));
    std.testing.refAllDecls(@import("providers/root.zig"));
    std.testing.refAllDecls(@import("transport/root.zig"));
    std.testing.refAllDecls(@import("routing/root.zig"));
}
