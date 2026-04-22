//! Integration: the token estimator is deterministic and reachable via
//! the library surface.

const std = @import("std");
const tigerclaw = @import("tigerclaw");

const testing = std.testing;

test "estimate reachable via the llm surface" {
    const est = tigerclaw.llm.token_estimator.estimate("hello, world");
    // 12 bytes ceil-div 4 → 3 tokens.
    try testing.expectEqual(@as(u32, 3), est);
}

test "estimate is stable across repeated calls on identical input" {
    const s = "the quick brown fox jumps over the lazy dog";
    const a = tigerclaw.llm.token_estimator.estimate(s);
    const b = tigerclaw.llm.token_estimator.estimate(s);
    try testing.expectEqual(a, b);
}
