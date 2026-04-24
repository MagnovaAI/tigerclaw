//! Context-window budget.
//!
//! Every model has a hard cap on how many tokens a single request
//! can carry. A session grows its transcript over time; once the
//! cumulative token count gets close to the cap, something has to
//! give — either drop old messages, summarise them, or refuse the
//! turn. The `Window` is the tiny value type that drives those
//! decisions.
//!
//! The estimator here uses the existing `llm.token_estimator` —
//! the same deterministic 4-bytes-per-token heuristic that the
//! ledger and budget use. Exact tokenisation is a provider-side
//! concern; this layer only needs a safe overestimate so the
//! runtime refuses to send a request that will trip the cap.

const std = @import("std");
const types = @import("types");
const token_estimator = @import("../../llm/token_estimator.zig");

pub const Window = struct {
    /// Provider-reported context cap, in tokens.
    capacity_tokens: u32,
    /// Tokens we leave uncommitted for the assistant's reply.
    /// Production defaults target ~25 % headroom on typical
    /// caps; callers tune per model.
    reserve_output_tokens: u32 = 4_096,

    /// Headroom currently available for prompt tokens.
    pub fn promptBudget(self: Window) u32 {
        if (self.reserve_output_tokens >= self.capacity_tokens) return 0;
        return self.capacity_tokens - self.reserve_output_tokens;
    }

    /// Estimate the token cost of a message list. Deterministic.
    pub fn estimateMessages(self: Window, messages: []const types.Message) u32 {
        _ = self;
        var total: u64 = 0;
        for (messages) |m| total +|= token_estimator.estimate(m.flatText());
        // Saturate to u32 — this is a budget check, not a billing
        // record, so clamping is safer than returning an error.
        return if (total > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(total);
    }

    /// Classify a candidate prompt against the budget.
    pub fn classify(self: Window, estimated_prompt_tokens: u32) Status {
        const budget = self.promptBudget();
        if (estimated_prompt_tokens > budget) return .overflow;
        if (budget == 0) return .overflow;
        const used_pct = percent(estimated_prompt_tokens, budget);
        if (used_pct >= 90) return .pressure;
        if (used_pct >= 70) return .warm;
        return .ok;
    }

    fn percent(numer: u32, denom: u32) u32 {
        if (denom == 0) return 100;
        return @intCast(@as(u64, numer) * 100 / denom);
    }
};

pub const Status = enum {
    /// Plenty of room; no compaction needed.
    ok,
    /// Past 70 % — compaction should be considered before the
    /// next turn fills the remaining headroom.
    warm,
    /// Past 90 % — compaction is due before dispatch.
    pressure,
    /// Budget would be exceeded by this prompt.
    overflow,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Window.promptBudget: reserves output tokens" {
    const w = Window{ .capacity_tokens = 10_000, .reserve_output_tokens = 2_000 };
    try testing.expectEqual(@as(u32, 8_000), w.promptBudget());
}

test "Window.classify: ok/warm/pressure/overflow thresholds" {
    const w = Window{ .capacity_tokens = 1_000, .reserve_output_tokens = 0 };
    try testing.expectEqual(Status.ok, w.classify(100));
    try testing.expectEqual(Status.warm, w.classify(800));
    try testing.expectEqual(Status.pressure, w.classify(950));
    try testing.expectEqual(Status.overflow, w.classify(1_001));
}

test "Window.estimateMessages: aggregates across messages" {
    const w = Window{ .capacity_tokens = 1_000 };
    const msgs = [_]types.Message{
        types.Message.literal(.user, "a" ** 100),
        types.Message.literal(.assistant, "b" ** 100),
    };
    const est = w.estimateMessages(&msgs);
    // Estimator is ceil(bytes/4) per message → 25 + 25 = 50.
    try testing.expect(est >= 50);
}

test "Window.classify: zero budget always overflows" {
    const w = Window{ .capacity_tokens = 10, .reserve_output_tokens = 10 };
    try testing.expectEqual(Status.overflow, w.classify(0));
}
