//! Token-bucket rate limiter.
//!
//! Deterministic by construction: the limiter holds its own monotonic
//! clock-ns count, advanced by the caller via `advanceNs`. The harness
//! drives the advance; tests can too. No global clock, no std.time.

const std = @import("std");

pub const Limiter = struct {
    capacity: u32,
    refill_per_sec: u32,
    tokens: u32,
    last_ns: i128,

    pub fn init(capacity: u32, refill_per_sec: u32) Limiter {
        return .{
            .capacity = capacity,
            .refill_per_sec = refill_per_sec,
            .tokens = capacity,
            .last_ns = 0,
        };
    }

    /// Advance the limiter's internal clock. Negative deltas are
    /// clamped to zero (defensive; a non-monotonic caller is a bug).
    pub fn advanceNs(self: *Limiter, delta_ns: i128) void {
        if (delta_ns <= 0) return;
        self.last_ns += delta_ns;
        const refill_tokens: u64 = @intCast(@divFloor(
            @as(i128, self.refill_per_sec) * delta_ns,
            std.time.ns_per_s,
        ));
        const new_tokens: u64 = @as(u64, self.tokens) + refill_tokens;
        self.tokens = @intCast(@min(new_tokens, @as(u64, self.capacity)));
    }

    /// Attempt to consume `n` tokens. Returns true on success.
    pub fn tryConsume(self: *Limiter, n: u32) bool {
        if (self.tokens < n) return false;
        self.tokens -= n;
        return true;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Limiter: starts full and consumes down" {
    var l = Limiter.init(5, 10);
    try testing.expect(l.tryConsume(3));
    try testing.expectEqual(@as(u32, 2), l.tokens);
}

test "Limiter: refuses consumption beyond tokens" {
    var l = Limiter.init(2, 10);
    try testing.expect(l.tryConsume(2));
    try testing.expect(!l.tryConsume(1));
}

test "Limiter: advanceNs refills proportionally" {
    var l = Limiter.init(10, 10); // 10 tokens per second.
    _ = l.tryConsume(10);
    try testing.expectEqual(@as(u32, 0), l.tokens);
    l.advanceNs(500 * std.time.ns_per_ms); // 0.5s → 5 tokens.
    try testing.expectEqual(@as(u32, 5), l.tokens);
}

test "Limiter: refill caps at capacity" {
    var l = Limiter.init(4, 100);
    _ = l.tryConsume(4);
    l.advanceNs(2 * std.time.ns_per_s); // would yield 200 tokens.
    try testing.expectEqual(@as(u32, 4), l.tokens);
}

test "Limiter: negative delta is ignored" {
    var l = Limiter.init(4, 10);
    _ = l.tryConsume(2);
    l.advanceNs(-1_000_000);
    try testing.expectEqual(@as(u32, 2), l.tokens);
}
