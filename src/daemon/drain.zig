//! Bounded wait helper for the gateway shutdown path.
//!
//! Once the gateway flips its `should_stop` flag, the daemon main
//! loop still has to wait for in-flight work (open TCP connections,
//! pending writes) to finish before it tears the process down. This
//! module owns that wait: it polls a caller-supplied predicate at a
//! fixed cadence until the predicate reports drained, or a deadline
//! elapses.
//!
//! Everything routes through `std.Io`. Zig 0.16 removed
//! `std.Thread.sleep`, `std.Thread.ResetEvent`, and `std.time.Timer`,
//! so we use `std.Io.sleep` for the cadence and accumulate elapsed
//! nanoseconds ourselves rather than reaching for a timer.

const std = @import("std");

pub const DrainError = error{Timeout};

pub const Options = struct {
    poll_interval_ns: u64 = 10 * std.time.ns_per_ms,
    deadline_ns: u64 = 5 * std.time.ns_per_s,
};

pub const Predicate = *const fn (ctx: ?*anyopaque) bool;

/// Poll `predicate` until it returns true or the deadline elapses.
///
/// The predicate is invoked once before the first sleep so that an
/// already-drained system returns immediately without paying the
/// poll-interval latency. Sleeps are best-effort: any error from
/// `std.Io.sleep` is swallowed and the elapsed counter still advances
/// by the requested interval, which keeps the deadline honest even
/// when the runtime cuts a sleep short.
pub fn waitFor(
    io: std.Io,
    predicate: Predicate,
    ctx: ?*anyopaque,
    opts: Options,
) DrainError!void {
    if (predicate(ctx)) return;

    var elapsed_ns: u64 = 0;
    while (elapsed_ns < opts.deadline_ns) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(opts.poll_interval_ns)), .awake) catch {};
        elapsed_ns +|= opts.poll_interval_ns;
        if (predicate(ctx)) return;
    }
    return error.Timeout;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Counter = struct {
    calls: u32 = 0,
    true_at: u32,
};

fn countingPredicate(ctx: ?*anyopaque) bool {
    const c: *Counter = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    return c.calls >= c.true_at;
}

fn alwaysFalse(ctx: ?*anyopaque) bool {
    if (ctx) |raw| {
        const c: *Counter = @ptrCast(@alignCast(raw));
        c.calls += 1;
    }
    return false;
}

test "waitFor returns immediately when predicate is already true" {
    var c: Counter = .{ .true_at = 1 };
    try waitFor(testing.io, countingPredicate, &c, .{
        .poll_interval_ns = 1 * std.time.ns_per_ms,
        .deadline_ns = 100 * std.time.ns_per_ms,
    });
    try testing.expectEqual(@as(u32, 1), c.calls);
}

test "waitFor succeeds once predicate flips after several polls" {
    var c: Counter = .{ .true_at = 3 };
    try waitFor(testing.io, countingPredicate, &c, .{
        .poll_interval_ns = 1 * std.time.ns_per_ms,
        .deadline_ns = 100 * std.time.ns_per_ms,
    });
    try testing.expectEqual(@as(u32, 3), c.calls);
}

test "waitFor returns Timeout when predicate never trips" {
    var c: Counter = .{ .true_at = 0 };
    try testing.expectError(error.Timeout, waitFor(testing.io, alwaysFalse, &c, .{
        .poll_interval_ns = 1 * std.time.ns_per_ms,
        .deadline_ns = 10 * std.time.ns_per_ms,
    }));
    try testing.expect(c.calls >= 1);
}

test "waitFor with zero deadline still consults predicate once (success)" {
    var c: Counter = .{ .true_at = 1 };
    try waitFor(testing.io, countingPredicate, &c, .{
        .poll_interval_ns = 1 * std.time.ns_per_ms,
        .deadline_ns = 0,
    });
    try testing.expectEqual(@as(u32, 1), c.calls);
}

test "waitFor with zero deadline and false predicate times out" {
    var c: Counter = .{ .true_at = 0 };
    try testing.expectError(error.Timeout, waitFor(testing.io, alwaysFalse, &c, .{
        .poll_interval_ns = 1 * std.time.ns_per_ms,
        .deadline_ns = 0,
    }));
    try testing.expectEqual(@as(u32, 1), c.calls);
}
