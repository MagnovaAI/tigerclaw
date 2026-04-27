//! Token counts reported by a provider for a single call.

const std = @import("std");

pub const TokenUsage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,

    pub fn total(self: TokenUsage) u64 {
        return @as(u64, self.input) +| self.output +| self.cache_read +| self.cache_write;
    }

    /// Tokens occupying the provider's context window on the most
    /// recent call: prompt tokens (`input`) plus tokens read from
    /// or written to the prompt cache. Excludes `output` because
    /// those are produced after the window is sized.
    pub fn contextTokens(self: TokenUsage) u64 {
        return @as(u64, self.input) +| self.cache_read +| self.cache_write;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "TokenUsage: total sums all buckets" {
    const u = TokenUsage{ .input = 100, .output = 50, .cache_read = 10, .cache_write = 5 };
    try testing.expectEqual(@as(u64, 165), u.total());
}

test "TokenUsage: JSON roundtrip preserves every bucket" {
    const u = TokenUsage{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4 };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, u, .{});
    defer testing.allocator.free(s);

    const parsed = try std.json.parseFromSlice(TokenUsage, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expectEqual(u.input, parsed.value.input);
    try testing.expectEqual(u.output, parsed.value.output);
    try testing.expectEqual(u.cache_read, parsed.value.cache_read);
    try testing.expectEqual(u.cache_write, parsed.value.cache_write);
}

test "TokenUsage: defaults are zero" {
    const u = TokenUsage{};
    try testing.expectEqual(@as(u64, 0), u.total());
}
