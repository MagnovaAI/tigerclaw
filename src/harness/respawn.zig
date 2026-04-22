//! Session respawn policy.
//!
//! A "respawn" is the harness's reaction to a fatal turn: the session
//! is restarted (its in-memory turn state is reset) so the agent can
//! try again on the next user message, without the user needing to
//! restart the process. This is the tigerclaw analogue of the v1
//! daemon's supervisor-with-backoff, scoped to one session rather
//! than the whole process.
//!
//! Policy parameters:
//!   * `max_respawns` — total number of respawns permitted over the
//!     session's lifetime. `0` disables respawning entirely (any
//!     fatal turn stops the session).
//!   * `backoff_ns`  — delay applied by the caller between the
//!     fatal turn and the next attempt. Tracked here so callers can
//!     ask "how long should I wait before respawning?" without
//!     duplicating the schedule logic.
//!
//! The policy is intentionally tiny. Tighter controls (per-reason
//! caps, cooldown windows, operator acknowledgement) are deferred
//! until the react loop actually uses them — YAGNI until we have
//! real failure data to tune against.

const std = @import("std");

pub const Policy = struct {
    /// Hard cap on total respawns. `0` means respawning is disabled.
    max_respawns: u32 = 0,
    /// Initial backoff before the first respawn, in nanoseconds.
    initial_backoff_ns: u64 = 0,
    /// Multiplier applied to the backoff after every respawn.
    /// `1` = constant backoff. `2` = exponential doubling, etc.
    backoff_multiplier: u32 = 1,
    /// Upper bound on backoff. `0` means no cap.
    max_backoff_ns: u64 = 0,
};

pub const Decision = enum { allow, exhausted };

pub const Controller = struct {
    policy: Policy,
    respawn_count: u32 = 0,

    pub fn init(policy: Policy) Controller {
        return .{ .policy = policy };
    }

    pub fn count(self: *const Controller) u32 {
        return self.respawn_count;
    }

    /// Ask for permission to respawn. If granted, the caller MUST
    /// treat the session as respawned — `respawn_count` is bumped
    /// here so repeat calls without progress eventually reach
    /// `.exhausted`.
    pub fn decide(self: *Controller) Decision {
        if (self.respawn_count >= self.policy.max_respawns) return .exhausted;
        self.respawn_count += 1;
        return .allow;
    }

    /// How long the caller should sleep before the next attempt, given
    /// the number of respawns that have already occurred. Exposed as
    /// a pure function of `respawn_count` so callers can compute the
    /// backoff without mutating the controller (e.g. for logging).
    pub fn backoffForCount(self: *const Controller, n: u32) u64 {
        if (self.policy.initial_backoff_ns == 0 or n == 0) return 0;

        // Exponential backoff: initial * multiplier^(n-1). Saturating
        // multiplies prevent the pathological case where the operator
        // set a huge multiplier with no max_backoff_ns cap.
        var delay: u64 = self.policy.initial_backoff_ns;
        var i: u32 = 1;
        while (i < n) : (i += 1) {
            const mul: u64 = self.policy.backoff_multiplier;
            const next = std.math.mul(u64, delay, mul) catch std.math.maxInt(u64);
            delay = next;
            if (self.policy.max_backoff_ns != 0 and delay > self.policy.max_backoff_ns) {
                delay = self.policy.max_backoff_ns;
                break;
            }
        }
        if (self.policy.max_backoff_ns != 0 and delay > self.policy.max_backoff_ns) {
            delay = self.policy.max_backoff_ns;
        }
        return delay;
    }

    /// Convenience: backoff for the next respawn given the current
    /// counter. Safe to call before `decide()`.
    pub fn nextBackoffNs(self: *const Controller) u64 {
        return self.backoffForCount(self.respawn_count + 1);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Controller: disabled policy always exhausted" {
    var c = Controller.init(.{});
    try testing.expectEqual(Decision.exhausted, c.decide());
    try testing.expectEqual(@as(u32, 0), c.count());
}

test "Controller: allows up to max_respawns then exhausts" {
    var c = Controller.init(.{ .max_respawns = 2 });
    try testing.expectEqual(Decision.allow, c.decide());
    try testing.expectEqual(Decision.allow, c.decide());
    try testing.expectEqual(Decision.exhausted, c.decide());
    try testing.expectEqual(@as(u32, 2), c.count());
}

test "Controller: constant backoff stays constant" {
    const c = Controller.init(.{
        .max_respawns = 10,
        .initial_backoff_ns = 1_000,
        .backoff_multiplier = 1,
    });
    try testing.expectEqual(@as(u64, 1_000), c.backoffForCount(1));
    try testing.expectEqual(@as(u64, 1_000), c.backoffForCount(5));
}

test "Controller: exponential backoff doubles" {
    const c = Controller.init(.{
        .max_respawns = 10,
        .initial_backoff_ns = 100,
        .backoff_multiplier = 2,
    });
    try testing.expectEqual(@as(u64, 0), c.backoffForCount(0));
    try testing.expectEqual(@as(u64, 100), c.backoffForCount(1));
    try testing.expectEqual(@as(u64, 200), c.backoffForCount(2));
    try testing.expectEqual(@as(u64, 400), c.backoffForCount(3));
}

test "Controller: backoff respects max_backoff_ns cap" {
    const c = Controller.init(.{
        .max_respawns = 10,
        .initial_backoff_ns = 100,
        .backoff_multiplier = 10,
        .max_backoff_ns = 500,
    });
    try testing.expectEqual(@as(u64, 100), c.backoffForCount(1));
    try testing.expectEqual(@as(u64, 500), c.backoffForCount(2));
    try testing.expectEqual(@as(u64, 500), c.backoffForCount(9));
}

test "Controller: zero initial backoff yields zero delay" {
    const c = Controller.init(.{ .max_respawns = 5 });
    try testing.expectEqual(@as(u64, 0), c.backoffForCount(3));
}

test "Controller: nextBackoffNs reflects upcoming attempt" {
    var c = Controller.init(.{
        .max_respawns = 5,
        .initial_backoff_ns = 10,
        .backoff_multiplier = 2,
    });
    try testing.expectEqual(@as(u64, 10), c.nextBackoffNs());
    _ = c.decide();
    try testing.expectEqual(@as(u64, 20), c.nextBackoffNs());
    _ = c.decide();
    try testing.expectEqual(@as(u64, 40), c.nextBackoffNs());
}
