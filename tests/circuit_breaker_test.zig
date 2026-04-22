//! Integration: the breaker composes with classifier + retry attempt
//! reports — a sequence of failures trips the breaker; a successful
//! trial closes it.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const reliability = tigerclaw.llm.reliability;

const testing = std.testing;

test "breaker: threshold failures trip, cooldown opens trial, success closes" {
    var b = reliability.Breaker.init(.{ .failure_threshold = 3, .cooldown_ns = 1_000 });

    try testing.expect(b.allow(0));
    b.recordFailure(0);
    b.recordFailure(100);
    try testing.expectEqual(reliability.BreakerState.closed, b.state);
    b.recordFailure(200);
    try testing.expectEqual(reliability.BreakerState.open, b.state);

    try testing.expect(!b.allow(500));
    try testing.expect(b.allow(1_200)); // cooldown elapsed
    try testing.expectEqual(reliability.BreakerState.half_open, b.state);

    b.recordSuccess(1_200);
    try testing.expectEqual(reliability.BreakerState.closed, b.state);
    try testing.expectEqual(@as(u32, 0), b.failures);
}

test "breaker: half_open failure reopens with a fresh cooldown" {
    var b = reliability.Breaker.init(.{ .failure_threshold = 1, .cooldown_ns = 1_000 });
    b.recordFailure(0);
    _ = b.allow(1_000); // → half_open
    b.recordFailure(1_100);
    try testing.expectEqual(reliability.BreakerState.open, b.state);
    try testing.expect(!b.allow(1_200));
    try testing.expect(b.allow(2_100));
}
