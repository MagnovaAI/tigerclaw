//! Per-model context-window sizing.
//!
//! Centralises the max-context lookup and the "how much room to
//! reserve for the model's output" math. Two consumers share this:
//!
//!   1. the TUI status bar (so the bar reads `<used>/<max>`)
//!   2. the runner's prompt assembler (so we don't shove more
//!      tokens into the prompt than the model can accept)
//!
//! Lookup is by substring match against the model id; new entries
//! land at the top of `entries` so longer-needle matches win over
//! shorter ones (`claude-haiku-4` before `claude-3`).

const std = @import("std");

/// Max context window in tokens. Returns `0` when the model id is
/// unknown — callers must treat that as "fall back to a safe
/// default" rather than "no limit".
pub fn maxContext(model_id: []const u8) u64 {
    const entries = [_]struct { needle: []const u8, max: u64 }{
        .{ .needle = "claude-opus-4", .max = 1_000_000 },
        .{ .needle = "claude-sonnet-4", .max = 1_000_000 },
        .{ .needle = "claude-haiku-4", .max = 200_000 },
        .{ .needle = "claude-3", .max = 200_000 },
        .{ .needle = "gpt-5", .max = 256_000 },
        .{ .needle = "gpt-4", .max = 128_000 },
    };
    for (entries) |e| {
        if (std.mem.indexOf(u8, model_id, e.needle) != null) return e.max;
    }
    return 0;
}

/// Number of tokens the assembler may put into the prompt for this
/// model. Reserves room for the model's output so the request does
/// not bounce off the provider's window. The reserve is the larger
/// of `min_reserve` and 15% of the window — empirically what hermes
/// and the openai cookbook recommend for chat-style sessions.
pub fn promptBudget(model_id: []const u8) u32 {
    const max = maxContext(model_id);
    const fallback: u32 = 64 * 1024;
    if (max == 0) return fallback;

    const min_reserve: u64 = 4096;
    const pct_reserve = max / 7; // ~14%
    const reserve = if (pct_reserve > min_reserve) pct_reserve else min_reserve;
    const budget = if (max > reserve) max - reserve else max / 2;

    // Clamp to u32 — sections's `token_estimate` is u32 and the
    // assembler folds budget into a u32 sum.
    if (budget > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(budget);
}

const testing = std.testing;

test "maxContext: known models" {
    try testing.expectEqual(@as(u64, 1_000_000), maxContext("claude-opus-4-7"));
    try testing.expectEqual(@as(u64, 1_000_000), maxContext("anthropic claude-sonnet-4-6"));
    try testing.expectEqual(@as(u64, 200_000), maxContext("claude-haiku-4-5-20251001"));
    try testing.expectEqual(@as(u64, 200_000), maxContext("claude-3-5-sonnet"));
    try testing.expectEqual(@as(u64, 128_000), maxContext("gpt-4o"));
    try testing.expectEqual(@as(u64, 256_000), maxContext("gpt-5"));
}

test "maxContext: unknown returns zero" {
    try testing.expectEqual(@as(u64, 0), maxContext("mock"));
    try testing.expectEqual(@as(u64, 0), maxContext("custom-model"));
}

test "promptBudget: leaves headroom for output" {
    const claude_opus = promptBudget("claude-opus-4-7");
    try testing.expect(claude_opus < 1_000_000);
    try testing.expect(claude_opus > 800_000);

    const claude_haiku = promptBudget("claude-haiku-4-5");
    try testing.expect(claude_haiku < 200_000);
    try testing.expect(claude_haiku > 160_000);
}

test "promptBudget: unknown model falls back to 64k" {
    try testing.expectEqual(@as(u32, 64 * 1024), promptBudget("mock"));
}
