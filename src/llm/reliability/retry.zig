//! Bounded-retry helper with deterministic backoff.
//!
//! `run` calls `fn_ptr` up to `max_attempts` times. Retryable and
//! rate-limited errors schedule the next attempt; everything else
//! returns immediately. Backoff is computed against a `*std.Random` so
//! determinism is the caller's choice (tests pass a seeded RNG; prod
//! uses `determinism.Rng.initFromOs`).
//!
//! This module does NOT sleep. It computes how long each attempt
//! should wait and returns that to the caller (or a harness-owned
//! scheduler); inline `std.Thread.sleep` is unavailable in 0.16, and a
//! sleep loop is the scheduler's job, not this helper's. The `run`
//! entry point is therefore synchronous and optimistic — useful for
//! in-process tests and the harness can wrap it with its own pacing
//! around cancellation.

const std = @import("std");
const classifier = @import("error_classifier.zig");

pub const Policy = struct {
    max_attempts: u8 = 3,
    base_backoff_ms: u32 = 100,
    rate_limit_backoff_ms: u32 = 1_000,
    jitter_pct: u8 = 25,
};

pub const Attempt = struct {
    attempt: u8, // 1-based
    delay_ms: u32,
    class: classifier.Class,
};

/// Returns the backoff the caller should honour before retrying. The
/// formula is `base * 2^(attempt-1)` plus jitter in ±jitter_pct.
pub fn scheduleBackoff(
    policy: Policy,
    class: classifier.Class,
    attempt: u8,
    rng: *std.Random,
) u32 {
    const base: u32 = switch (class) {
        .rate_limited => policy.rate_limit_backoff_ms,
        else => policy.base_backoff_ms,
    };
    const shift = @min(attempt -| 1, @as(u8, 16));
    const expo: u32 = base << @intCast(shift);

    if (policy.jitter_pct == 0) return expo;
    const span = (expo / 100) * policy.jitter_pct;
    if (span == 0) return expo;
    const delta_raw = rng.int(u32) % (span * 2 + 1);
    const delta: i64 = @as(i64, delta_raw) - @as(i64, span);
    const adjusted: i64 = @as(i64, expo) + delta;
    if (adjusted < 0) return 0;
    return @intCast(adjusted);
}

pub const Outcome = union(enum) {
    ok,
    err: anyerror,
};

/// Runs `op` with retries. Sleep between attempts is the caller's
/// responsibility — this helper only returns each attempt's backoff via
/// `report`.
pub fn run(
    comptime T: type,
    policy: Policy,
    rng: *std.Random,
    context: anytype,
    comptime op: fn (@TypeOf(context)) anyerror!T,
    report: *std.array_list.Aligned(Attempt, null),
    allocator: std.mem.Allocator,
) anyerror!T {
    var attempt: u8 = 0;
    while (true) {
        attempt += 1;
        if (op(context)) |value| {
            return value;
        } else |err| {
            const class = classifier.classify(err);
            if (class == .terminal or attempt >= policy.max_attempts) return err;
            const delay = scheduleBackoff(policy, class, attempt, rng);
            try report.append(allocator, .{ .attempt = attempt, .delay_ms = delay, .class = class });
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const determinism = @import("../../determinism.zig");

fn seededRandom() std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(determinism.fixed_seed);
}

const Counter = struct {
    hits: u32 = 0,
    fail_first_n: u32 = 0,
    terminal_err: bool = false,
};

fn tryCounter(c: *Counter) anyerror!u32 {
    c.hits += 1;
    if (c.terminal_err) return error.InvalidArgument;
    if (c.hits <= c.fail_first_n) return error.Unavailable;
    return c.hits;
}

test "scheduleBackoff: grows exponentially and is deterministic under seed" {
    var prng = seededRandom();
    var r = prng.random();
    const policy = Policy{ .base_backoff_ms = 10, .jitter_pct = 0 };

    try testing.expectEqual(@as(u32, 10), scheduleBackoff(policy, .retryable, 1, &r));
    try testing.expectEqual(@as(u32, 20), scheduleBackoff(policy, .retryable, 2, &r));
    try testing.expectEqual(@as(u32, 40), scheduleBackoff(policy, .retryable, 3, &r));
}

test "scheduleBackoff: rate-limit uses its own base" {
    var prng = seededRandom();
    var r = prng.random();
    const policy = Policy{
        .base_backoff_ms = 10,
        .rate_limit_backoff_ms = 500,
        .jitter_pct = 0,
    };
    try testing.expectEqual(@as(u32, 500), scheduleBackoff(policy, .rate_limited, 1, &r));
    try testing.expectEqual(@as(u32, 1000), scheduleBackoff(policy, .rate_limited, 2, &r));
}

test "run: eventually succeeds after retryable failures" {
    var counter = Counter{ .fail_first_n = 2 };
    var prng = seededRandom();
    var r = prng.random();

    var report: std.array_list.Aligned(Attempt, null) = .empty;
    defer report.deinit(testing.allocator);

    const value = try run(
        u32,
        .{ .max_attempts = 5, .base_backoff_ms = 1, .jitter_pct = 0 },
        &r,
        &counter,
        tryCounter,
        &report,
        testing.allocator,
    );

    try testing.expectEqual(@as(u32, 3), value);
    try testing.expectEqual(@as(u32, 3), counter.hits);
    try testing.expectEqual(@as(usize, 2), report.items.len);
}

test "run: terminal error surfaces immediately" {
    var counter = Counter{ .terminal_err = true };
    var prng = seededRandom();
    var r = prng.random();

    var report: std.array_list.Aligned(Attempt, null) = .empty;
    defer report.deinit(testing.allocator);

    try testing.expectError(error.InvalidArgument, run(
        u32,
        .{ .max_attempts = 5 },
        &r,
        &counter,
        tryCounter,
        &report,
        testing.allocator,
    ));
    try testing.expectEqual(@as(u32, 1), counter.hits);
    try testing.expectEqual(@as(usize, 0), report.items.len);
}

test "run: gives up after max_attempts" {
    var counter = Counter{ .fail_first_n = 99 };
    var prng = seededRandom();
    var r = prng.random();

    var report: std.array_list.Aligned(Attempt, null) = .empty;
    defer report.deinit(testing.allocator);

    try testing.expectError(error.Unavailable, run(
        u32,
        .{ .max_attempts = 3, .base_backoff_ms = 1, .jitter_pct = 0 },
        &r,
        &counter,
        tryCounter,
        &report,
        testing.allocator,
    ));
    try testing.expectEqual(@as(u32, 3), counter.hits);
    try testing.expectEqual(@as(usize, 2), report.items.len);
}
