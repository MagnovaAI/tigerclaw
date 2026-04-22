//! Convert `types.TokenUsage` + model price into a cost in
//! micro-USD. This is the one place where "how many tokens" meets
//! "how much money" — isolating the conversion here keeps the
//! ledger's arithmetic pure and the pricing table swappable.

const std = @import("std");
const types = @import("../types/root.zig");
const pricing = @import("pricing.zig");

/// Result of pricing a single usage record.
pub const Priced = struct {
    /// Total cost in micro-USD.
    cost_micros: u64,
    /// Breakdown per bucket. Mostly useful for the reporter; the
    /// ledger only sums `cost_micros`.
    input_micros: u64,
    output_micros: u64,
    cache_read_micros: u64,
    cache_write_micros: u64,
    /// Flag set when the model was not found in the price table.
    /// In that case every bucket is zero but the caller may want
    /// to log a warning so an operator notices missing entries
    /// before they are billed by surprise.
    unknown_model: bool,
};

/// Price a single call. Cache-read/cache-write fall back to
/// `input` when their specific rates are zero; this matches every
/// provider we have seen, where "no cache pricing configured"
/// effectively means "same as input".
pub fn priceUsage(
    table: []const pricing.ModelPrice,
    model: []const u8,
    usage: types.TokenUsage,
) Priced {
    const entry = pricing.lookup(table, model) orelse {
        return .{
            .cost_micros = 0,
            .input_micros = 0,
            .output_micros = 0,
            .cache_read_micros = 0,
            .cache_write_micros = 0,
            .unknown_model = true,
        };
    };

    const cache_read_rate = if (entry.cache_read != 0) entry.cache_read else entry.input;
    const cache_write_rate = if (entry.cache_write != 0) entry.cache_write else entry.input;

    const in_cost = pricing.costMicros(@as(u64, usage.input), entry.input);
    const out_cost = pricing.costMicros(@as(u64, usage.output), entry.output);
    const cr_cost = pricing.costMicros(@as(u64, usage.cache_read), cache_read_rate);
    const cw_cost = pricing.costMicros(@as(u64, usage.cache_write), cache_write_rate);

    // Each sum uses saturating addition so a pathological model
    // price cannot wrap a `u64` and produce negative-looking
    // cost_micros downstream.
    const total = in_cost +| out_cost +| cr_cost +| cw_cost;

    return .{
        .cost_micros = total,
        .input_micros = in_cost,
        .output_micros = out_cost,
        .cache_read_micros = cr_cost,
        .cache_write_micros = cw_cost,
        .unknown_model = false,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "priceUsage: known model sums every bucket" {
    const table = [_]pricing.ModelPrice{
        .{ .model = "m1", .input = 3_000_000, .output = 15_000_000 },
    };
    const usage = types.TokenUsage{ .input = 1_000_000, .output = 500_000 };
    const p = priceUsage(&table, "m1", usage);
    try testing.expect(!p.unknown_model);
    // 1M in @ $3/M = 3_000_000 micros; 0.5M out @ $15/M = 7_500_000.
    try testing.expectEqual(@as(u64, 3_000_000), p.input_micros);
    try testing.expectEqual(@as(u64, 7_500_000), p.output_micros);
    try testing.expectEqual(@as(u64, 10_500_000), p.cost_micros);
}

test "priceUsage: unknown model reports zero cost + unknown_model flag" {
    const p = priceUsage(&.{}, "ghost", .{ .input = 100 });
    try testing.expect(p.unknown_model);
    try testing.expectEqual(@as(u64, 0), p.cost_micros);
}

test "priceUsage: cache rates fall back to input rate when unset" {
    const table = [_]pricing.ModelPrice{
        .{ .model = "m1", .input = 1_000_000, .output = 1_000_000 },
    };
    const usage = types.TokenUsage{ .cache_read = 1_000_000, .cache_write = 1_000_000 };
    const p = priceUsage(&table, "m1", usage);
    // Fall-back to input (1_000_000 micros each).
    try testing.expectEqual(@as(u64, 1_000_000), p.cache_read_micros);
    try testing.expectEqual(@as(u64, 1_000_000), p.cache_write_micros);
    try testing.expectEqual(@as(u64, 2_000_000), p.cost_micros);
}

test "priceUsage: explicit cache rates beat fallback" {
    const table = [_]pricing.ModelPrice{
        .{ .model = "m1", .input = 1_000_000, .output = 1_000_000, .cache_read = 100_000 },
    };
    const usage = types.TokenUsage{ .cache_read = 1_000_000 };
    const p = priceUsage(&table, "m1", usage);
    try testing.expectEqual(@as(u64, 100_000), p.cache_read_micros);
}
