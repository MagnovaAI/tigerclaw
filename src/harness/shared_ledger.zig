//! Caller-facing wrapper around `cost.Ledger`.
//!
//! The raw ledger exposes `reserve` / `commit` / `release` as three
//! independent calls. That is the right shape for the storage
//! layer, but it puts the burden of "always settle a reservation"
//! on every caller. In a long-running agent loop with dozens of
//! provider calls, one missed release leaks headroom until the
//! session resets.
//!
//! `Held` is the `defer`-friendly wrapper: the caller obtains one
//! via `SharedLedger.reserve(...)`, then either calls
//! `.commit(actual)` or `.release()` before dropping it. If the
//! caller forgets, `.deinit()` (run via `defer`) refunds the
//! reservation automatically. That makes the ergonomic pattern:
//!
//!     var held = try shared.reserve(upper_bound);
//!     defer held.deinit();
//!     // ... do the provider call ...
//!     try held.commit(actual_micros);
//!
//! If the call fails after `reserve` but before `commit`, `defer`
//! releases the money. If the call succeeds, `commit` has already
//! marked the `Held` as settled, so `deinit` becomes a no-op.
//!
//! `SharedLedger` itself is just a thin shared-reference type
//! over a `*cost.Ledger`. The wrapper does not own the ledger —
//! the harness does — so multiple sessions can cooperate on one
//! budget without double-frees.

const std = @import("std");
const cost = @import("../cost/root.zig");

pub const Error = cost.ledger.Error;
pub const Reservation = cost.ledger.Reservation;

/// Shared ledger reference. Holds no state beyond the pointer +
/// the allocator used for the reservation map, so copying one is
/// free and threadsafe.
pub const SharedLedger = struct {
    ledger: *cost.Ledger,
    allocator: std.mem.Allocator,

    pub fn init(ledger: *cost.Ledger, allocator: std.mem.Allocator) SharedLedger {
        return .{ .ledger = ledger, .allocator = allocator };
    }

    /// Reserve `upper_bound_micros` and return an auto-releasing
    /// `Held`. On success the reservation is live; the caller
    /// *must* eventually call `.commit` or `.release` (or rely on
    /// `defer held.deinit()` to refund).
    pub fn reserve(self: SharedLedger, upper_bound_micros: u64) !Held {
        const res = try self.ledger.reserve(self.allocator, upper_bound_micros);
        return .{
            .owner = self,
            .reservation = res,
            .state = .live,
        };
    }
};

/// Settle-or-release-on-drop reservation handle.
pub const Held = struct {
    owner: SharedLedger,
    reservation: Reservation,
    state: State,

    const State = enum {
        /// Reservation is alive and must be settled before drop
        /// (or `deinit` will refund it).
        live,
        /// Already committed — `deinit` is a no-op.
        committed,
        /// Already released — `deinit` is a no-op.
        released,
    };

    /// The amount originally reserved, exposed so callers that
    /// want to clamp their actual usage know the upper bound.
    pub fn reserved(self: Held) u64 {
        return self.reservation.amount_micros;
    }

    /// Finalise with the real cost. `actual_micros` must be ≤
    /// `reserved()`. Idempotent is NOT a goal: calling `.commit`
    /// twice is a usage bug and surfaces as `UnknownReservation`.
    pub fn commit(self: *Held, actual_micros: u64) !void {
        try self.owner.ledger.commit(self.reservation, actual_micros);
        self.state = .committed;
    }

    /// Give the reservation back unconsumed. Intended for the
    /// explicit "call cancelled" path; the implicit path is
    /// `defer held.deinit()`.
    pub fn release(self: *Held) !void {
        try self.owner.ledger.release(self.reservation);
        self.state = .released;
    }

    /// Run under `defer` to guarantee settlement. On an already
    /// committed/released reservation this is a no-op. Errors
    /// from a defensive release are swallowed because `deinit`
    /// cannot return one — the reservation is a stack value
    /// going out of scope either way, and a leak here would be
    /// silently papered over by the eventual session reset.
    /// Swallowing keeps the expected "forgot to settle" path
    /// obvious in logs rather than hidden behind an unreachable.
    pub fn deinit(self: *Held) void {
        if (self.state != .live) return;
        self.owner.ledger.release(self.reservation) catch |err| {
            std.log.scoped(.shared_ledger).warn(
                "auto-release failed for reservation {d}: {any}",
                .{ self.reservation.id, err },
            );
        };
        self.state = .released;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn newLedger() cost.Ledger {
    return cost.Ledger.init(1_000_000);
}

test "SharedLedger: reserve + commit settles the reservation" {
    var ledger = newLedger();
    defer ledger.deinit(testing.allocator);
    const shared = SharedLedger.init(&ledger, testing.allocator);

    var held = try shared.reserve(10_000);
    defer held.deinit();

    try testing.expectEqual(@as(u64, 10_000), held.reserved());
    try testing.expectEqual(@as(u64, 10_000), ledger.totals().pending_micros);

    try held.commit(7_500);
    try testing.expectEqual(@as(u64, 0), ledger.totals().pending_micros);
    try testing.expectEqual(@as(u64, 7_500), ledger.totals().spent_micros);

    // Extra deinit after commit must be a no-op — ledger totals
    // do not change.
    held.deinit();
    try testing.expectEqual(@as(u64, 7_500), ledger.totals().spent_micros);
}

test "SharedLedger: release returns the full reservation" {
    var ledger = newLedger();
    defer ledger.deinit(testing.allocator);
    const shared = SharedLedger.init(&ledger, testing.allocator);

    var held = try shared.reserve(5_000);
    defer held.deinit();

    try held.release();
    try testing.expectEqual(@as(u64, 0), ledger.totals().pending_micros);
    try testing.expectEqual(@as(u64, 0), ledger.totals().spent_micros);
}

test "SharedLedger: defer refunds when neither commit nor release is called" {
    var ledger = newLedger();
    defer ledger.deinit(testing.allocator);
    const shared = SharedLedger.init(&ledger, testing.allocator);

    {
        var held = try shared.reserve(800);
        defer held.deinit();
        // Simulate a provider call that errored out: no commit, no
        // explicit release. `defer` is responsible for refunding.
        try testing.expectEqual(@as(u64, 800), ledger.totals().pending_micros);
    }
    // Reservation is released — pending is back to zero.
    try testing.expectEqual(@as(u64, 0), ledger.totals().pending_micros);
}

test "SharedLedger: over-commit surfaces and leaves the reservation live" {
    var ledger = newLedger();
    defer ledger.deinit(testing.allocator);
    const shared = SharedLedger.init(&ledger, testing.allocator);

    var held = try shared.reserve(100);
    defer held.deinit();
    try testing.expectError(Error.OverCommit, held.commit(101));

    // The reservation is still live — defer will refund it, so
    // pending must stay at 100 until scope exit.
    try testing.expectEqual(@as(u64, 100), ledger.totals().pending_micros);
}

test "SharedLedger: ceiling breach propagates as an error from reserve" {
    var tight = cost.Ledger.init(1_000);
    defer tight.deinit(testing.allocator);
    const shared = SharedLedger.init(&tight, testing.allocator);

    _ = try shared.reserve(1_000);
    try testing.expectError(Error.CeilingExceeded, shared.reserve(1));
}

test "SharedLedger: commit then re-commit fails and state is sticky" {
    var ledger = newLedger();
    defer ledger.deinit(testing.allocator);
    const shared = SharedLedger.init(&ledger, testing.allocator);

    var held = try shared.reserve(100);
    defer held.deinit();

    try held.commit(50);
    // Second commit must fail — reservation already gone from the
    // ledger. This is the "did the caller accidentally commit
    // twice?" safety net.
    try testing.expectError(Error.UnknownReservation, held.commit(10));
    try testing.expectEqual(@as(u64, 50), ledger.totals().spent_micros);
}
