//! Deterministic, provider-agnostic token estimate.
//!
//! This is not a tokenizer. It is a pre-flight sizing heuristic used for
//! budget reservation and for the bench layer's token-use buckets. The
//! rule is fixed: ceil(len / 4). Production's cost ledger re-reads the
//! real count from `ChatResponse.usage` post-call.
//!
//! Tests: edge cases around rounding and empty input.

pub const bytes_per_token: u32 = 4;

pub fn estimate(text: []const u8) u32 {
    const n = text.len;
    // Ceil division without overflow: (n + bpt - 1) / bpt
    const est = (n + bytes_per_token - 1) / bytes_per_token;
    const max: usize = @intCast(@as(u32, 0xFFFF_FFFF));
    return @intCast(@min(est, max));
}

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "estimate: empty string is 0" {
    try testing.expectEqual(@as(u32, 0), estimate(""));
}

test "estimate: one character rounds up to 1" {
    try testing.expectEqual(@as(u32, 1), estimate("a"));
}

test "estimate: 4 bytes → 1, 5 bytes → 2" {
    try testing.expectEqual(@as(u32, 1), estimate("abcd"));
    try testing.expectEqual(@as(u32, 2), estimate("abcde"));
}

test "estimate: stable across byte-identical inputs" {
    try testing.expectEqual(estimate("hello, world"), estimate("hello, world"));
}

test "estimate: linear table" {
    const cases = [_]struct { input: []const u8, expected: u32 }{
        .{ .input = "", .expected = 0 },
        .{ .input = "a", .expected = 1 },
        .{ .input = "abcd", .expected = 1 },
        .{ .input = "abcde", .expected = 2 },
        .{ .input = "abcdefgh", .expected = 2 },
        .{ .input = "abcdefghi", .expected = 3 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.expected, estimate(c.input));
    }
}
