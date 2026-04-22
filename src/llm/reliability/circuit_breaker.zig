//! Three-state circuit breaker.
//!
//! States:
//!
//!   closed    normal: requests flow through, failures accumulate
//!   open      failures crossed the threshold; calls short-circuit
//!             until `cooldown_ns` elapses
//!   half_open one trial call is permitted; success closes the breaker,
//!             failure reopens with a fresh cooldown
//!
//! The breaker holds no clock of its own. Callers pass an `i128` now
//! on every `allow`, `recordSuccess`, or `recordFailure` call — this
//! keeps the breaker deterministic under the harness's injected clock.

const std = @import("std");

pub const State = enum { closed, open, half_open };

pub const Config = struct {
    failure_threshold: u32 = 5,
    cooldown_ns: i128 = std.time.ns_per_s * 10,
};

pub const Breaker = struct {
    config: Config,
    state: State = .closed,
    failures: u32 = 0,
    opened_at_ns: i128 = 0,

    pub fn init(config: Config) Breaker {
        return .{ .config = config };
    }

    /// Returns true when the caller may proceed. Transitions open →
    /// half_open if the cooldown has elapsed.
    pub fn allow(self: *Breaker, now_ns: i128) bool {
        switch (self.state) {
            .closed, .half_open => return true,
            .open => {
                if (now_ns - self.opened_at_ns >= self.config.cooldown_ns) {
                    self.state = .half_open;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *Breaker, _: i128) void {
        self.state = .closed;
        self.failures = 0;
    }

    pub fn recordFailure(self: *Breaker, now_ns: i128) void {
        switch (self.state) {
            .half_open => {
                self.state = .open;
                self.opened_at_ns = now_ns;
                self.failures = self.config.failure_threshold;
            },
            .closed, .open => {
                self.failures +|= 1;
                if (self.failures >= self.config.failure_threshold and self.state != .open) {
                    self.state = .open;
                    self.opened_at_ns = now_ns;
                }
            },
        }
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Breaker: stays closed until threshold is reached" {
    var b = Breaker.init(.{ .failure_threshold = 3 });
    try testing.expect(b.allow(0));
    b.recordFailure(0);
    b.recordFailure(0);
    try testing.expectEqual(State.closed, b.state);
    b.recordFailure(0);
    try testing.expectEqual(State.open, b.state);
    try testing.expect(!b.allow(0));
}

test "Breaker: open transitions to half_open after cooldown" {
    var b = Breaker.init(.{ .failure_threshold = 1, .cooldown_ns = 100 });
    b.recordFailure(0);
    try testing.expectEqual(State.open, b.state);
    try testing.expect(!b.allow(50));
    try testing.expect(b.allow(100));
    try testing.expectEqual(State.half_open, b.state);
}

test "Breaker: half_open success closes breaker" {
    var b = Breaker.init(.{ .failure_threshold = 1, .cooldown_ns = 100 });
    b.recordFailure(0);
    _ = b.allow(100);
    b.recordSuccess(100);
    try testing.expectEqual(State.closed, b.state);
    try testing.expectEqual(@as(u32, 0), b.failures);
}

test "Breaker: half_open failure reopens with fresh cooldown" {
    var b = Breaker.init(.{ .failure_threshold = 1, .cooldown_ns = 100 });
    b.recordFailure(0);
    _ = b.allow(100);
    b.recordFailure(150);
    try testing.expectEqual(State.open, b.state);
    try testing.expectEqual(@as(i128, 150), b.opened_at_ns);
    try testing.expect(!b.allow(200));
    try testing.expect(b.allow(250));
}

test "Breaker: success under closed state resets counter" {
    var b = Breaker.init(.{ .failure_threshold = 5 });
    b.recordFailure(0);
    b.recordFailure(0);
    try testing.expectEqual(@as(u32, 2), b.failures);
    b.recordSuccess(0);
    try testing.expectEqual(@as(u32, 0), b.failures);
}
