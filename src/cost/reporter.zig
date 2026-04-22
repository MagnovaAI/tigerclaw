//! Per-model cost aggregation.
//!
//! The `Ledger` only tracks `spent` and `pending` totals — it has
//! no notion of which model ran up the bill. The `Reporter` holds
//! that breakdown separately so the hot ledger path stays cheap
//! and the aggregation logic can evolve without touching it.
//!
//! Callers `record(model, usage, cost)` after each `commit`, then
//! `snapshot(allocator)` to get a sorted list of per-model totals
//! for UI / logs / CI reports. The list is sorted by descending
//! cost so the noisiest model is always at the top.

const std = @import("std");
const types = @import("../types/root.zig");
const pricing = @import("pricing.zig");
const usage_pricing = @import("usage_pricing.zig");

pub const ModelTotals = struct {
    model: []const u8,
    calls: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cost_micros: u64 = 0,
};

pub const Reporter = struct {
    allocator: std.mem.Allocator,
    /// Per-model totals keyed by model id (owned strings).
    by_model: std.StringHashMap(ModelTotals),

    pub fn init(allocator: std.mem.Allocator) Reporter {
        return .{
            .allocator = allocator,
            .by_model = std.StringHashMap(ModelTotals).init(allocator),
        };
    }

    pub fn deinit(self: *Reporter) void {
        var it = self.by_model.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.by_model.deinit();
    }

    pub fn record(
        self: *Reporter,
        model: []const u8,
        usage: types.TokenUsage,
        cost_micros: u64,
    ) !void {
        const gop = try self.by_model.getOrPut(model);
        if (!gop.found_existing) {
            // Hash-map key must outlive the caller's `model` slice.
            gop.key_ptr.* = try self.allocator.dupe(u8, model);
            gop.value_ptr.* = .{ .model = gop.key_ptr.* };
        }
        gop.value_ptr.calls +|= 1;
        gop.value_ptr.input_tokens +|= usage.input;
        gop.value_ptr.output_tokens +|= usage.output;
        gop.value_ptr.cache_read_tokens +|= usage.cache_read;
        gop.value_ptr.cache_write_tokens +|= usage.cache_write;
        gop.value_ptr.cost_micros +|= cost_micros;
    }

    /// Convenience wrapper: price the usage and record it in one
    /// call. Mirrors `Ledger.commitUsage` so providers that use
    /// both can feed the same input in twice without rebuilding.
    pub fn recordUsage(
        self: *Reporter,
        table: []const pricing.ModelPrice,
        model: []const u8,
        usage: types.TokenUsage,
    ) !usage_pricing.Priced {
        const priced = usage_pricing.priceUsage(table, model, usage);
        try self.record(model, usage, priced.cost_micros);
        return priced;
    }

    /// Return a caller-owned sorted slice of model totals,
    /// heaviest spender first. Caller frees the slice; the
    /// contained `model` strings alias the reporter's own keys
    /// and remain valid until `deinit`.
    pub fn snapshot(self: *Reporter, allocator: std.mem.Allocator) ![]ModelTotals {
        const out = try allocator.alloc(ModelTotals, self.by_model.count());
        errdefer allocator.free(out);
        var idx: usize = 0;
        var it = self.by_model.valueIterator();
        while (it.next()) |v| : (idx += 1) out[idx] = v.*;

        // Sort descending by cost, breaking ties on model name so
        // the output is deterministic under replay.
        std.mem.sort(ModelTotals, out, {}, cmpDesc);
        return out;
    }

    fn cmpDesc(_: void, a: ModelTotals, b: ModelTotals) bool {
        if (a.cost_micros != b.cost_micros) return a.cost_micros > b.cost_micros;
        return std.mem.order(u8, a.model, b.model) == .lt;
    }

    /// Sum of `cost_micros` across every model. Cheaper than
    /// snapshotting when the caller only wants a grand total.
    pub fn grandTotalMicros(self: *Reporter) u64 {
        var total: u64 = 0;
        var it = self.by_model.valueIterator();
        while (it.next()) |v| total +|= v.cost_micros;
        return total;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Reporter: record accumulates per model" {
    var r = Reporter.init(testing.allocator);
    defer r.deinit();

    try r.record("m1", .{ .input = 10, .output = 20 }, 100);
    try r.record("m1", .{ .input = 5, .output = 7 }, 50);
    try r.record("m2", .{ .input = 1 }, 1_000);

    const snap = try r.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("m2", snap[0].model); // heaviest first
    try testing.expectEqual(@as(u64, 1_000), snap[0].cost_micros);

    try testing.expectEqualStrings("m1", snap[1].model);
    try testing.expectEqual(@as(u64, 150), snap[1].cost_micros);
    try testing.expectEqual(@as(u64, 15), snap[1].input_tokens);
    try testing.expectEqual(@as(u64, 27), snap[1].output_tokens);
    try testing.expectEqual(@as(u64, 2), snap[1].calls);
}

test "Reporter: ties break deterministically on model name" {
    var r = Reporter.init(testing.allocator);
    defer r.deinit();
    try r.record("z", .{}, 100);
    try r.record("a", .{}, 100);

    const snap = try r.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings("a", snap[0].model);
    try testing.expectEqualStrings("z", snap[1].model);
}

test "Reporter: recordUsage prices and records in one step" {
    const table = [_]pricing.ModelPrice{
        .{ .model = "m", .input = 1_000_000, .output = 1_000_000 },
    };

    var r = Reporter.init(testing.allocator);
    defer r.deinit();

    const priced = try r.recordUsage(&table, "m", .{ .input = 1_000_000 });
    try testing.expectEqual(@as(u64, 1_000_000), priced.cost_micros);

    try testing.expectEqual(@as(u64, 1_000_000), r.grandTotalMicros());
}

test "Reporter: grandTotalMicros across many models" {
    var r = Reporter.init(testing.allocator);
    defer r.deinit();
    try r.record("a", .{}, 1);
    try r.record("b", .{}, 2);
    try r.record("c", .{}, 4);
    try testing.expectEqual(@as(u64, 7), r.grandTotalMicros());
}
