//! Model pricing tables and arithmetic.
//!
//! All amounts are in integer **micro-USD** (10^-6 USD). Every
//! layer above (`ledger`, `reporter`, `budget.cost_micros`) uses
//! the same integer base so there is exactly one rounding step —
//! at the point where a `PricePerMillionTokens` × token-count
//! multiplication happens. Downstream aggregation never touches
//! floating point.
//!
//! Why integers:
//!   * Deterministic under replay. f64 accumulation depends on
//!     addition order; a cost ledger summed across multiple
//!     threads would drift between runs.
//!   * Budgets compare via `>=`; no epsilon fuzz needed.
//!   * Serialisable as exact JSON numbers.

const std = @import("std");

/// Price per one million tokens, in micro-USD.
///
/// Example: Claude Sonnet input at $3.00/M → 3_000_000. The unit
/// size matches the typical "per million" publishing convention so
/// operators can paste the posted price directly (scaled × 10^6).
pub const PricePerMillionMicros = u64;

pub const ModelPrice = struct {
    /// Canonical model identifier (matches
    /// `types.ModelRef.model`).
    model: []const u8,
    input: PricePerMillionMicros,
    output: PricePerMillionMicros,
    /// Prompt-cache read price. `0` = no cache pricing (fall back
    /// to `input`).
    cache_read: PricePerMillionMicros = 0,
    /// Prompt-cache write price. `0` = same as `input`.
    cache_write: PricePerMillionMicros = 0,
};

/// Compute cost in micro-USD for a token count at a given price.
///
/// Integer formula: `ceil(tokens * price / 1_000_000)`. Ceiling
/// (rather than round or floor) is the safer default: it keeps
/// our accounting a penny ahead of the provider's billing, so the
/// budget trips at or before the real dollar threshold.
pub fn costMicros(tokens: u64, price_per_million: PricePerMillionMicros) u64 {
    if (tokens == 0 or price_per_million == 0) return 0;
    const numerator = std.math.mul(u64, tokens, price_per_million) catch return std.math.maxInt(u64);
    return (numerator + 1_000_000 - 1) / 1_000_000;
}

/// Return the `ModelPrice` entry for `model`, or `null` if not
/// found. Callers decide what to do about unknown models — the
/// ledger treats unknown as zero-cost but sets a flag (see
/// `usage_pricing.zig`).
pub fn lookup(table: []const ModelPrice, model: []const u8) ?ModelPrice {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.model, model)) return entry;
    }
    return null;
}

/// Default price table. Kept tiny on purpose — operators are
/// expected to override via settings when deploying. The values
/// here are illustrative ballparks, not authoritative.
pub const default_table = [_]ModelPrice{
    .{ .model = "claude-sonnet-4", .input = 3_000_000, .output = 15_000_000 },
    .{ .model = "claude-opus-4", .input = 15_000_000, .output = 75_000_000 },
    .{ .model = "claude-haiku-4", .input = 250_000, .output = 1_250_000 },
    .{ .model = "mock", .input = 0, .output = 0 },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "costMicros: zero tokens or zero price is zero" {
    try testing.expectEqual(@as(u64, 0), costMicros(0, 1_000));
    try testing.expectEqual(@as(u64, 0), costMicros(1_000, 0));
}

test "costMicros: exact division gives exact answer" {
    // 1M tokens @ 3 USD/M = 3 USD = 3_000_000 micros.
    try testing.expectEqual(@as(u64, 3_000_000), costMicros(1_000_000, 3_000_000));
}

test "costMicros: ceiling bias keeps accounting safe" {
    // 1 token at $3/M = 3 micro-USD, but a fraction: ceil → 3.
    try testing.expectEqual(@as(u64, 3), costMicros(1, 3_000_000));
    // 1 token at $0.25/M = 0.25 micro → ceil 1 micro.
    try testing.expectEqual(@as(u64, 1), costMicros(1, 250_000));
}

test "costMicros: overflow saturates instead of trapping" {
    const big: u64 = std.math.maxInt(u64);
    const out = costMicros(big, big);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), out);
}

test "lookup: hits and misses behave as documented" {
    try testing.expect(lookup(&default_table, "claude-sonnet-4") != null);
    try testing.expect(lookup(&default_table, "not-a-real-model") == null);
}
