//! Cost ledger with two-phase accounting.
//!
//! Why two phases: a concurrent request can be in-flight before the
//! provider has told us the real token count. If two requests both
//! read "spent = X", both decide "there is $Y headroom", and both
//! fire, we can overshoot the operator's budget.
//!
//! The ledger fixes this with the classic reserve / commit / release
//! protocol:
//!
//!   1. `reserve(upper_bound)` — atomically add `upper_bound` to
//!      `pending` if adding it would not exceed the ceiling.
//!      Returns a `Reservation` handle.
//!   2. `commit(res, actual)` — move the reservation's budget out
//!      of `pending` and add `actual` to `spent`. `actual` must
//!      be ≤ the reserved amount.
//!   3. `release(res)` — give the reservation back unconsumed
//!      (e.g. the call was cancelled).
//!
//! Anything not commited or released is effectively a leak on the
//! budget. Reservations are cheap plain-data values, not pointers,
//! so losing the stack frame that owns one is the same as
//! forgetting to call `release` — the budget stays tight until a
//! matching call eventually arrives or the ledger is reset.
//!
//! `pending + spent` is the canonical "amount the operator has
//! committed to spending now or soon". Never compare `spent` alone
//! against the ceiling — that is what causes the race.

const std = @import("std");
const types = @import("types");
const pricing = @import("pricing.zig");
const usage_pricing = @import("usage_pricing.zig");

/// Tiny spinlock. Zig 0.16's `std.Io.Mutex` requires an `Io`
/// handle on every lock/unlock, which would contaminate every
/// caller of this ledger. `std.atomic.Value(bool)` with a
/// test-and-set loop gives us a zero-dep mutex that is correct
/// for short critical sections; the ledger only holds it long
/// enough to mutate a couple of fields.
const Spinlock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *Spinlock) void {
        while (true) {
            if (self.state.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return;
            // Another thread holds the lock. Yielding (rather than
            // pure spin) is kind to the OS scheduler.
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Spinlock) void {
        self.state.store(false, .release);
    }
};

pub const Error = error{
    /// The ceiling would be breached. Returned by `reserve`.
    CeilingExceeded,
    /// `commit` was asked to book more than the reservation held.
    OverCommit,
    /// The reservation handle did not match anything held by the
    /// ledger. Indicates a double-release or cross-ledger mix-up.
    UnknownReservation,
};

/// Handle returned by `reserve`. Opaque by intent: callers should
/// not read the fields directly; they exist only so this is a
/// plain value (stackable, comparable) rather than a pointer.
pub const Reservation = struct {
    id: u64,
    amount_micros: u64,
};

pub const Totals = struct {
    spent_micros: u64,
    pending_micros: u64,

    /// Everything currently counted against the budget.
    pub fn committed(self: Totals) u64 {
        return self.spent_micros +| self.pending_micros;
    }
};

/// Thread-safe cost ledger.
///
/// Uses a mutex rather than atomics because every operation needs
/// to mutate multiple fields coherently (e.g. `commit` must drop
/// pending *and* bump spent as one step). Contention is low — one
/// lock per API call, no contention during streaming reads — so
/// the lock cost is negligible.
pub const Ledger = struct {
    /// Budget ceiling. `0` means "no ceiling" (reservations always
    /// succeed on capacity, only fail via OverCommit).
    ceiling_micros: u64,
    /// Monotonic id source for reservations. Wrapping is fine — id
    /// reuse only matters if billions of reservations are alive at
    /// the same time, which is not a real workload.
    next_id: u64 = 1,
    spent_micros: u64 = 0,
    pending_micros: u64 = 0,
    /// Live reservations, keyed by id. Bounded by how many
    /// in-flight calls the runtime has.
    reservations: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    mutex: Spinlock = .{},

    pub fn init(ceiling_micros: u64) Ledger {
        return .{ .ceiling_micros = ceiling_micros };
    }

    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator) void {
        self.reservations.deinit(allocator);
        self.* = undefined;
    }

    /// Reserve `upper_bound` micros against the budget.
    pub fn reserve(
        self: *Ledger,
        allocator: std.mem.Allocator,
        upper_bound: u64,
    ) !Reservation {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ceiling_micros != 0) {
            const committed = self.spent_micros +| self.pending_micros;
            const would_be = committed +| upper_bound;
            if (would_be > self.ceiling_micros) return Error.CeilingExceeded;
        }

        const id = self.next_id;
        self.next_id += 1;
        try self.reservations.put(allocator, id, upper_bound);
        self.pending_micros +|= upper_bound;
        return .{ .id = id, .amount_micros = upper_bound };
    }

    /// Finalise a reservation with the real cost. `actual` must be
    /// ≤ the reserved amount.
    pub fn commit(self: *Ledger, res: Reservation, actual_micros: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const held = self.reservations.get(res.id) orelse return Error.UnknownReservation;
        if (actual_micros > held) return Error.OverCommit;
        _ = self.reservations.remove(res.id);
        self.pending_micros -|= held;
        self.spent_micros +|= actual_micros;
    }

    /// Give a reservation back unconsumed. Idempotent on the
    /// "already released" case? No — a double-release is a bug
    /// and surfaces `UnknownReservation`. We deliberately do not
    /// swallow that so call-site leaks (double free, missing
    /// reservation threading) surface loudly in tests.
    pub fn release(self: *Ledger, res: Reservation) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const held = self.reservations.get(res.id) orelse return Error.UnknownReservation;
        _ = self.reservations.remove(res.id);
        self.pending_micros -|= held;
    }

    /// Record a cost that was already incurred outside the
    /// reserve/commit dance (e.g. a non-metered tool call or a
    /// test harness). This is the escape hatch for callers that
    /// measure cost post-hoc; it skips the ceiling check because
    /// the money has already been spent — refusing the record
    /// would hide reality without preventing it.
    pub fn recordDirect(self: *Ledger, cost_micros: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.spent_micros +|= cost_micros;
    }

    pub fn totals(self: *Ledger) Totals {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .spent_micros = self.spent_micros,
            .pending_micros = self.pending_micros,
        };
    }

    /// Convenience: price a `TokenUsage` against the table and
    /// commit. Used by provider wrappers that already hold a
    /// `Reservation`. Returns the cost that was committed so
    /// callers can log it.
    pub fn commitUsage(
        self: *Ledger,
        table: []const pricing.ModelPrice,
        model: []const u8,
        usage: types.TokenUsage,
        res: Reservation,
    ) !u64 {
        const priced = usage_pricing.priceUsage(table, model, usage);
        // If the usage exceeds the reservation, clamp to the
        // reservation and record the shortfall via recordDirect
        // below. That keeps the ledger honest without breaking
        // the reserve/commit invariant.
        const actual = if (priced.cost_micros > res.amount_micros) res.amount_micros else priced.cost_micros;
        const shortfall = priced.cost_micros - actual;
        try self.commit(res, actual);
        if (shortfall > 0) self.recordDirect(shortfall);
        return priced.cost_micros;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Ledger: reserve/commit happy path" {
    var l = Ledger.init(1_000_000);
    defer l.deinit(testing.allocator);

    const r = try l.reserve(testing.allocator, 100_000);
    try testing.expectEqual(@as(u64, 100_000), l.totals().pending_micros);
    try testing.expectEqual(@as(u64, 0), l.totals().spent_micros);

    try l.commit(r, 80_000);
    try testing.expectEqual(@as(u64, 0), l.totals().pending_micros);
    try testing.expectEqual(@as(u64, 80_000), l.totals().spent_micros);
}

test "Ledger: reserve refuses to exceed ceiling" {
    var l = Ledger.init(500);
    defer l.deinit(testing.allocator);

    const r = try l.reserve(testing.allocator, 400);
    try testing.expectError(Error.CeilingExceeded, l.reserve(testing.allocator, 200));
    try l.commit(r, 400);

    // After commit: spent=400, pending=0. A reserve that would
    // take total above the 500 ceiling must fail.
    try testing.expectError(Error.CeilingExceeded, l.reserve(testing.allocator, 200));
    // But a reserve that fits within the remaining 100 headroom
    // must succeed.
    _ = try l.reserve(testing.allocator, 50);
}

test "Ledger: release frees the reserved amount" {
    var l = Ledger.init(1_000);
    defer l.deinit(testing.allocator);

    const r = try l.reserve(testing.allocator, 800);
    try testing.expectEqual(@as(u64, 800), l.totals().pending_micros);

    try l.release(r);
    try testing.expectEqual(@as(u64, 0), l.totals().pending_micros);

    // Full headroom is available again.
    _ = try l.reserve(testing.allocator, 1_000);
}

test "Ledger: commit more than reserved is rejected" {
    var l = Ledger.init(1_000);
    defer l.deinit(testing.allocator);

    const r = try l.reserve(testing.allocator, 100);
    try testing.expectError(Error.OverCommit, l.commit(r, 101));

    // The reservation must still be alive after the failed commit
    // so the caller can release or retry.
    try l.release(r);
}

test "Ledger: double release surfaces UnknownReservation" {
    var l = Ledger.init(1_000);
    defer l.deinit(testing.allocator);

    const r = try l.reserve(testing.allocator, 100);
    try l.release(r);
    try testing.expectError(Error.UnknownReservation, l.release(r));
}

test "Ledger: commitUsage clamps overshoot and records shortfall" {
    var l = Ledger.init(10_000_000);
    defer l.deinit(testing.allocator);

    const table = [_]pricing.ModelPrice{
        .{ .model = "m", .input = 3_000_000, .output = 15_000_000 },
    };

    // Reserve 100 micros but actually consume way more.
    const r = try l.reserve(testing.allocator, 100);
    const real_cost = try l.commitUsage(&table, "m", .{ .input = 1_000_000 }, r);

    // Returned cost is the *real* price, not the clamped value.
    try testing.expectEqual(@as(u64, 3_000_000), real_cost);
    // Spent reflects both buckets (100 committed + 2_999_900 shortfall).
    try testing.expectEqual(@as(u64, 3_000_000), l.totals().spent_micros);
    // And nothing is left pending.
    try testing.expectEqual(@as(u64, 0), l.totals().pending_micros);
}

test "Ledger: concurrent reservations respect the ceiling" {
    // Spawn N threads each trying to reserve the same small chunk
    // against a tight ceiling. The count of successful reserves
    // must equal exactly floor(ceiling / chunk).
    var l = Ledger.init(10_000);
    defer l.deinit(testing.allocator);

    const chunk: u64 = 1_000;
    const thread_count: usize = 32;

    const Worker = struct {
        fn run(
            ledger: *Ledger,
            allocator: std.mem.Allocator,
            size: u64,
            counter: *std.atomic.Value(u32),
        ) void {
            if (ledger.reserve(allocator, size)) |_| {
                _ = counter.fetchAdd(1, .monotonic);
            } else |_| {}
        }
    };

    var successes = std.atomic.Value(u32).init(0);
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &l, testing.allocator, chunk, &successes });
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 10), successes.load(.monotonic));
    try testing.expectEqual(@as(u64, 10_000), l.totals().pending_micros);
}
