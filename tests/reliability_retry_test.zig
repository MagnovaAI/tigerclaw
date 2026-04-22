//! Integration: the retry helper driven by a seeded RNG produces a
//! stable sequence of attempt + backoff pairs.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const reliability = tigerclaw.llm.reliability;

const testing = std.testing;

const Counter = struct {
    hits: u32 = 0,
    fail_first_n: u32 = 0,
};

fn tryOp(c: *Counter) anyerror!u32 {
    c.hits += 1;
    if (c.hits <= c.fail_first_n) return error.RateLimited;
    return c.hits;
}

test "retry: RateLimited uses rate_limit_backoff_ms base" {
    var prng = std.Random.DefaultPrng.init(tigerclaw.determinism.fixed_seed);
    var r = prng.random();

    var counter = Counter{ .fail_first_n = 2 };
    var report: std.array_list.Aligned(reliability.retry.Attempt, null) = .empty;
    defer report.deinit(testing.allocator);

    const value = try reliability.retry.run(
        u32,
        .{ .max_attempts = 5, .base_backoff_ms = 10, .rate_limit_backoff_ms = 1000, .jitter_pct = 0 },
        &r,
        &counter,
        tryOp,
        &report,
        testing.allocator,
    );

    try testing.expectEqual(@as(u32, 3), value);
    try testing.expectEqual(@as(usize, 2), report.items.len);
    try testing.expectEqual(reliability.Class.rate_limited, report.items[0].class);
    // First attempt uses the 1 second rate-limit base.
    try testing.expectEqual(@as(u32, 1000), report.items[0].delay_ms);
    // Second attempt doubles.
    try testing.expectEqual(@as(u32, 2000), report.items[1].delay_ms);
}
