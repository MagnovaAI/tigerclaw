//! Per-provider request limits.
//!
//! Values mirror public documentation at the time of writing. They drift —
//! treat every constant here as a hint for pre-flight sizing, not an
//! authoritative cap. Actual enforcement lives in the rate-limit and
//! circuit-breaker modules.

pub const anthropic = struct {
    pub const max_input_tokens: u32 = 200_000;
    pub const max_output_tokens: u32 = 64_000;
    pub const max_requests_per_minute: u32 = 4_000;
};

pub const openai = struct {
    pub const max_input_tokens: u32 = 128_000;
    pub const max_output_tokens: u32 = 16_000;
    pub const max_requests_per_minute: u32 = 10_000;
};

pub const bedrock = struct {
    pub const max_input_tokens: u32 = 200_000;
    pub const max_output_tokens: u32 = 64_000;
    pub const max_requests_per_minute: u32 = 500;
};

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "api_limits: every provider sets max_input_tokens > 0" {
    try testing.expect(anthropic.max_input_tokens > 0);
    try testing.expect(openai.max_input_tokens > 0);
    try testing.expect(bedrock.max_input_tokens > 0);
}

test "api_limits: output cap is strictly below input cap for every provider" {
    try testing.expect(anthropic.max_output_tokens < anthropic.max_input_tokens);
    try testing.expect(openai.max_output_tokens < openai.max_input_tokens);
    try testing.expect(bedrock.max_output_tokens < bedrock.max_input_tokens);
}
