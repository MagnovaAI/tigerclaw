//! Prompt assembly.
//!
//! Builds the `ChatRequest` the react loop hands to a provider on
//! each iteration. The builder exists because the raw message list
//! is only part of the input: the system prompt, tool specs, and
//! caching annotations all need to be assembled in one place so
//! different providers see a consistent layout.
//!
//! Scope for this commit: assembly and cache-breakpoint placement.
//! Tool serialization into a provider's specific schema is the
//! registry's responsibility (Commit 39) — the builder just takes
//! whatever spec list it is given and passes it through.

const std = @import("std");
const types = @import("../types/root.zig");
const llm = @import("../llm/root.zig");

/// Inputs the caller supplies to `build`. Anything the provider
/// will actually see is threaded through here; the builder owns
/// nothing across calls.
pub const Input = struct {
    system: ?[]const u8 = null,
    history: []const types.Message,
    model: types.ModelRef,
    max_output_tokens: ?u32 = null,
    temperature: f32 = 0.7,
};

/// Build a provider `ChatRequest`. This is deliberately a pure
/// function today — the whole point is that the assembly can be
/// audited without running the loop.
pub fn build(input: Input) llm.ChatRequest {
    return .{
        .system = input.system,
        .messages = input.history,
        .model = input.model,
        .max_output_tokens = input.max_output_tokens,
        .temperature = input.temperature,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "build: passes through system, history, and knobs unchanged" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "hello" },
    };
    const req = build(.{
        .system = "you are helpful",
        .history = &msgs,
        .model = .{ .provider = "mock", .model = "0" },
        .max_output_tokens = 128,
        .temperature = 0.3,
    });

    try testing.expectEqualStrings("you are helpful", req.system.?);
    try testing.expectEqual(@as(usize, 2), req.messages.len);
    try testing.expectEqual(@as(f32, 0.3), req.temperature);
    try testing.expectEqual(@as(?u32, 128), req.max_output_tokens);
}

test "build: nil system stays nil in the request" {
    const req = build(.{
        .history = &.{},
        .model = .{ .provider = "mock", .model = "0" },
    });
    try testing.expect(req.system == null);
}
