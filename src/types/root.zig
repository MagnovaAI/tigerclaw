//! Canonical domain types used across subsystems.
//!
//! Each file defines one concept. They depend only on `std` and on each
//! other — no cross-subsystem imports.

const std = @import("std");

pub const Content = @import("content.zig").Content;
pub const ContentBlock = @import("message.zig").ContentBlock;
pub const LlmResponse = @import("llm_response.zig").LlmResponse;
pub const Message = @import("message.zig").Message;
pub const Metadata = @import("metadata.zig").Metadata;
pub const ModelRef = @import("model_ref.zig").ModelRef;
pub const Role = @import("message.zig").Role;
pub const StopReason = @import("llm_response.zig").StopReason;
pub const TokenUsage = @import("token_usage.zig").TokenUsage;
pub const Tool = @import("tool.zig").Tool;
pub const ToolCall = @import("tool_call.zig").ToolCall;
pub const ToolResult = @import("tool_result.zig").ToolResult;

test {
    std.testing.refAllDecls(@import("content.zig"));
    std.testing.refAllDecls(@import("llm_response.zig"));
    std.testing.refAllDecls(@import("message.zig"));
    std.testing.refAllDecls(@import("metadata.zig"));
    std.testing.refAllDecls(@import("model_ref.zig"));
    std.testing.refAllDecls(@import("token_usage.zig"));
    std.testing.refAllDecls(@import("tool.zig"));
    std.testing.refAllDecls(@import("tool_call.zig"));
    std.testing.refAllDecls(@import("tool_result.zig"));
}
