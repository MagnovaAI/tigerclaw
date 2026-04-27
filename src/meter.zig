//! Meter — passive budget accounting.
//!
//! Meters track consumable resources: tokens, dollars, wall-clock ms,
//! bytes, api calls. They do NOT refuse. Enforcement is the job of
//! guardrail-budget-* plugs which read the meter's remaining() and
//! return .deny(OverBudget) at policy thresholds.
//!
//! Why split accounting from enforcement? Two reasons:
//!   1. One meter, many policies. The same token ledger feeds a
//!      per-turn cap, a daily cap, and a per-tool cap without
//!      duplicating state.
//!   2. Meter stays simple. It's a ledger. Policy is politics.
//!
//! API shape:
//!   - reserve(kind, amount) → ReservationId
//!       Claims amount against remaining(); caller gets a handle.
//!   - consume(id)
//!       Finalize the reservation. Amount stays debited.
//!   - refund(id, unused)
//!       Return some of the reservation. Caller hands the handle back.
//!   - remaining(kind) → u64
//!       Current available budget.
//!
//! Concurrency: a single Meter instance is safe for one writer per
//! kind. Multi-writer use wraps with a Mutex.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §infrastructure.meter

const std = @import("std");
const errors = @import("errors");

const PlugError = errors.PlugError;

pub const Kind = enum(u8) {
    tokens, // LLM tokens consumed
    dollars_micros, // cost in millionths of a USD
    wall_ms, // wall-clock time budget
    bytes, // bandwidth / storage
    api_calls, // per-service call count

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .tokens => "tokens",
            .dollars_micros => "dollars_micros",
            .wall_ms => "wall_ms",
            .bytes => "bytes",
            .api_calls => "api_calls",
        };
    }
};

pub const ReservationId = u64;

/// Injectable meter. Plugs accept a `*const Meter` and call through
/// the vtable. Implementations decide the backing store (in-RAM for
/// meter-tokens, on-disk for meter-daily, etc.).
pub const Meter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reserve: *const fn (ptr: *anyopaque, kind: Kind, amount: u64) PlugError!ReservationId,
        consume: *const fn (ptr: *anyopaque, id: ReservationId) void,
        refund: *const fn (ptr: *anyopaque, id: ReservationId, unused: u64) void,
        remaining: *const fn (ptr: *anyopaque, kind: Kind) u64,
    };

    pub fn reserve(self: Meter, kind: Kind, amount: u64) PlugError!ReservationId {
        return self.vtable.reserve(self.ptr, kind, amount);
    }

    pub fn consume(self: Meter, id: ReservationId) void {
        self.vtable.consume(self.ptr, id);
    }

    pub fn refund(self: Meter, id: ReservationId, unused: u64) void {
        self.vtable.refund(self.ptr, id, unused);
    }

    pub fn remaining(self: Meter, kind: Kind) u64 {
        return self.vtable.remaining(self.ptr, kind);
    }
};

/// In-RAM meter. Backing impl for meter-tokens and meter-wall; both
/// are the same shape — one per kind with independent initial budget.
/// Concurrency: caller provides synchronization above this if needed.
pub const InMemoryMeter = struct {
    // Simple accounting: remaining per kind + reservations keyed by id.
    // Keeping both tokens and wall in a single InMemoryMeter is fine;
    // kind() dispatches to the right bucket.
    remainings: [5]u64, // indexed by @intFromEnum(Kind)
    next_id: u64 = 1,
    // Open reservations: id → (kind, amount)
    // Using a small fixed-capacity ring lets us avoid allocator in the
    // hot path. 1024 open reservations is generous for one agent.
    open: [1024]Reservation = [_]Reservation{.{ .id = 0, .kind = .tokens, .amount = 0 }} ** 1024,
    open_len: usize = 0,

    pub const Reservation = struct {
        id: ReservationId,
        kind: Kind,
        amount: u64,
    };

    pub fn init(initial: []const struct { kind: Kind, amount: u64 }) InMemoryMeter {
        var m = InMemoryMeter{ .remainings = [_]u64{0} ** 5 };
        for (initial) |entry| {
            m.remainings[@intFromEnum(entry.kind)] = entry.amount;
        }
        return m;
    }

    pub fn meter(self: *InMemoryMeter) Meter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reserveImpl(ptr: *anyopaque, kind: Kind, amount: u64) PlugError!ReservationId {
        const self: *InMemoryMeter = @ptrCast(@alignCast(ptr));
        if (self.open_len >= self.open.len) return error.Internal;

        // We DO NOT refuse on over-budget here — meter is passive.
        // remaining can go to zero or even wrap; guardrails see the
        // shortfall via remaining() and enforce.
        const rem = &self.remainings[@intFromEnum(kind)];
        rem.* = if (rem.* >= amount) rem.* - amount else 0;

        const id = self.next_id;
        self.next_id += 1;

        self.open[self.open_len] = .{ .id = id, .kind = kind, .amount = amount };
        self.open_len += 1;

        return id;
    }

    fn consumeImpl(ptr: *anyopaque, id: ReservationId) void {
        const self: *InMemoryMeter = @ptrCast(@alignCast(ptr));
        // Consume = keep the debit; just remove from open list.
        self.removeReservation(id);
    }

    fn refundImpl(ptr: *anyopaque, id: ReservationId, unused: u64) void {
        const self: *InMemoryMeter = @ptrCast(@alignCast(ptr));
        const r = self.findReservation(id) orelse return;
        const refund_amount = @min(unused, r.amount);
        self.remainings[@intFromEnum(r.kind)] += refund_amount;
        self.removeReservation(id);
    }

    fn remainingImpl(ptr: *anyopaque, kind: Kind) u64 {
        const self: *InMemoryMeter = @ptrCast(@alignCast(ptr));
        return self.remainings[@intFromEnum(kind)];
    }

    fn findReservation(self: *InMemoryMeter, id: ReservationId) ?Reservation {
        for (self.open[0..self.open_len]) |r| {
            if (r.id == id) return r;
        }
        return null;
    }

    fn removeReservation(self: *InMemoryMeter, id: ReservationId) void {
        var i: usize = 0;
        while (i < self.open_len) : (i += 1) {
            if (self.open[i].id == id) {
                self.open[i] = self.open[self.open_len - 1];
                self.open_len -= 1;
                return;
            }
        }
    }

    const vtable = Meter.VTable{
        .reserve = reserveImpl,
        .consume = consumeImpl,
        .refund = refundImpl,
        .remaining = remainingImpl,
    };
};

// --- contract -------------------------------------------------------------

/// Shared contract: every Meter implementation must satisfy these.
/// Call from contract tests of specific meter plugs.
pub fn runContract(m: Meter) !void {
    // reserve → remaining is decremented
    const rem0 = m.remaining(.tokens);
    const r1 = try m.reserve(.tokens, 100);
    const rem1 = m.remaining(.tokens);
    if (rem1 >= rem0) return error.TestReserveDidNotDecrementRemaining;

    // consume holds the debit
    m.consume(r1);
    const rem2 = m.remaining(.tokens);
    if (rem2 != rem1) return error.TestConsumeChangedRemaining;

    // reserve + refund returns remaining upward
    const r2 = try m.reserve(.tokens, 50);
    const rem3 = m.remaining(.tokens);
    m.refund(r2, 30);
    const rem4 = m.remaining(.tokens);
    if (rem4 != rem3 + 30) return error.TestRefundWrongAmount;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "InMemoryMeter: reserve decrements remaining" {
    var m = InMemoryMeter.init(&.{.{ .kind = .tokens, .amount = 1000 }});
    const meter = m.meter();

    try testing.expectEqual(@as(u64, 1000), meter.remaining(.tokens));
    const id = try meter.reserve(.tokens, 100);
    try testing.expectEqual(@as(u64, 900), meter.remaining(.tokens));
    meter.consume(id);
    try testing.expectEqual(@as(u64, 900), meter.remaining(.tokens));
}

test "InMemoryMeter: refund returns unused amount" {
    var m = InMemoryMeter.init(&.{.{ .kind = .tokens, .amount = 1000 }});
    const meter = m.meter();

    const id = try meter.reserve(.tokens, 100);
    try testing.expectEqual(@as(u64, 900), meter.remaining(.tokens));

    meter.refund(id, 60);
    try testing.expectEqual(@as(u64, 960), meter.remaining(.tokens));
}

test "InMemoryMeter: never refuses even over budget" {
    var m = InMemoryMeter.init(&.{.{ .kind = .tokens, .amount = 10 }});
    const meter = m.meter();

    // Reserve 100 tokens when only 10 remain. Meter clamps to 0;
    // enforcement is guardrail-budget-cap's job, not ours.
    const id = try meter.reserve(.tokens, 100);
    try testing.expectEqual(@as(u64, 0), meter.remaining(.tokens));
    meter.consume(id);
}

test "InMemoryMeter: multiple kinds tracked independently" {
    var m = InMemoryMeter.init(&.{
        .{ .kind = .tokens, .amount = 1000 },
        .{ .kind = .wall_ms, .amount = 5000 },
    });
    const meter = m.meter();

    try testing.expectEqual(@as(u64, 1000), meter.remaining(.tokens));
    try testing.expectEqual(@as(u64, 5000), meter.remaining(.wall_ms));

    _ = try meter.reserve(.tokens, 250);
    try testing.expectEqual(@as(u64, 1000 - 250), meter.remaining(.tokens));
    try testing.expectEqual(@as(u64, 5000), meter.remaining(.wall_ms)); // untouched
}

test "contract: InMemoryMeter passes runContract" {
    var m = InMemoryMeter.init(&.{.{ .kind = .tokens, .amount = 10_000 }});
    try runContract(m.meter());
}

test "Kind.name: returns canonical label" {
    try testing.expectEqualStrings("tokens", Kind.tokens.name());
    try testing.expectEqualStrings("dollars_micros", Kind.dollars_micros.name());
    try testing.expectEqualStrings("wall_ms", Kind.wall_ms.name());
}
