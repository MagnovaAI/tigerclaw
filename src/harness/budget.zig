//! Session budget accounting.
//!
//! A `Budget` bounds the resources one session is allowed to consume
//! before the harness halts further LLM calls. Four dimensions are
//! tracked independently; any one reaching its limit trips the budget:
//!
//!   * `turns`         — number of user→assistant cycles.
//!   * `input_tokens`  — cumulative prompt tokens sent to providers.
//!   * `output_tokens` — cumulative completion tokens received.
//!   * `cost_micros`   — cumulative dollars * 1e6 (integer, no FP drift).
//!
//! A limit of `0` means "no cap" on that axis. The common case is a
//! conversational cap on turns with a hard ceiling on cost to prevent
//! runaway spend; token caps are mostly for replay determinism.
//!
//! Thread-safety: counters are `std.atomic.Value(u64)` so that any
//! thread (including a streaming response reader that bills tokens as
//! chunks arrive) can call `recordTurn` without taking a lock.
//! Snapshots read the four axes separately, so a concurrent writer
//! can make the snapshot non-atomic across axes. That is acceptable
//! for budget checks: `exceeded()` is monotonic (counts only grow),
//! so the worst an observer sees is a slightly stale "not yet
//! exhausted" answer — they will see the trip on the next call. For
//! display purposes the skew is bounded by a single writer's delta.

const std = @import("std");

pub const Limits = struct {
    turns: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cost_micros: u64 = 0,
};

pub const Usage = struct {
    turns: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cost_micros: u64 = 0,
};

/// Which axis exhausted the budget, if any. Used so callers can surface
/// a precise reason to the user instead of a generic "limit reached".
pub const ExceededAxis = enum { none, turns, input_tokens, output_tokens, cost_micros };

pub const Budget = struct {
    limits: Limits,
    turns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    input_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    output_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cost_micros: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(limits: Limits) Budget {
        return .{ .limits = limits };
    }

    /// Read the current usage. Fields are loaded independently so the
    /// snapshot may not be atomic across all four axes — see the
    /// module-level comment for why that is acceptable.
    pub fn snapshot(self: *const Budget) Usage {
        return .{
            .turns = self.turns.load(.acquire),
            .input_tokens = self.input_tokens.load(.acquire),
            .output_tokens = self.output_tokens.load(.acquire),
            .cost_micros = self.cost_micros.load(.acquire),
        };
    }

    /// Record one completed turn and any tokens/cost it consumed.
    pub fn recordTurn(
        self: *Budget,
        input_tokens: u64,
        output_tokens: u64,
        cost_micros: u64,
    ) void {
        _ = self.turns.fetchAdd(1, .release);
        if (input_tokens != 0) _ = self.input_tokens.fetchAdd(input_tokens, .release);
        if (output_tokens != 0) _ = self.output_tokens.fetchAdd(output_tokens, .release);
        if (cost_micros != 0) _ = self.cost_micros.fetchAdd(cost_micros, .release);
    }

    /// Returns the first axis (in declaration order) whose usage has
    /// reached its configured limit. `Limits` values of 0 disable the
    /// corresponding axis.
    pub fn exceeded(self: *const Budget) ExceededAxis {
        const u = self.snapshot();
        if (self.limits.turns != 0 and u.turns >= self.limits.turns) return .turns;
        if (self.limits.input_tokens != 0 and u.input_tokens >= self.limits.input_tokens)
            return .input_tokens;
        if (self.limits.output_tokens != 0 and u.output_tokens >= self.limits.output_tokens)
            return .output_tokens;
        if (self.limits.cost_micros != 0 and u.cost_micros >= self.limits.cost_micros)
            return .cost_micros;
        return .none;
    }

    /// Fast boolean form of `exceeded`.
    pub fn isExhausted(self: *const Budget) bool {
        return self.exceeded() != .none;
    }

    /// Snapshot-style gate used before handing a request to the
    /// runner. This is deliberately *not* transactionally exact:
    /// the underlying counters can advance between the check and
    /// the runner accepting the turn, and that is fine — budget
    /// enforcement is a coarse safety net, not a serialisability
    /// invariant.
    pub fn check(self: *const Budget) ExceededAxis {
        return self.exceeded();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Budget: unlimited limits never trip" {
    var b = Budget.init(.{});
    b.recordTurn(10_000, 10_000, 10_000);
    try testing.expectEqual(ExceededAxis.none, b.exceeded());
    try testing.expect(!b.isExhausted());
}

test "Budget: turn limit trips exactly at the cap" {
    var b = Budget.init(.{ .turns = 2 });
    b.recordTurn(0, 0, 0);
    try testing.expectEqual(ExceededAxis.none, b.exceeded());
    b.recordTurn(0, 0, 0);
    try testing.expectEqual(ExceededAxis.turns, b.exceeded());
}

test "Budget: token limits trip on the correct axis" {
    var b = Budget.init(.{ .input_tokens = 100, .output_tokens = 50 });
    b.recordTurn(40, 10, 0);
    try testing.expectEqual(ExceededAxis.none, b.exceeded());
    b.recordTurn(60, 10, 0);
    try testing.expectEqual(ExceededAxis.input_tokens, b.exceeded());
}

test "Budget: cost axis reports cost_micros" {
    var b = Budget.init(.{ .cost_micros = 1_000 });
    b.recordTurn(0, 0, 500);
    try testing.expectEqual(ExceededAxis.none, b.exceeded());
    b.recordTurn(0, 0, 500);
    try testing.expectEqual(ExceededAxis.cost_micros, b.exceeded());
}

test "Budget: snapshot reflects accumulated usage" {
    var b = Budget.init(.{});
    b.recordTurn(1, 2, 3);
    b.recordTurn(4, 5, 6);
    const u = b.snapshot();
    try testing.expectEqual(@as(u64, 2), u.turns);
    try testing.expectEqual(@as(u64, 5), u.input_tokens);
    try testing.expectEqual(@as(u64, 7), u.output_tokens);
    try testing.expectEqual(@as(u64, 9), u.cost_micros);
}

test "Budget: earliest-declared axis wins when multiple are over" {
    var b = Budget.init(.{ .turns = 1, .cost_micros = 1 });
    b.recordTurn(0, 0, 10);
    try testing.expectEqual(ExceededAxis.turns, b.exceeded());
}

test "Budget: check is an alias for exceeded" {
    var b = Budget.init(.{ .turns = 1 });
    try testing.expectEqual(ExceededAxis.none, b.check());
    b.recordTurn(0, 0, 0);
    try testing.expectEqual(ExceededAxis.turns, b.check());
}

fn bumpTurnsWorker(b: *Budget, n: u64) void {
    var i: u64 = 0;
    while (i < n) : (i += 1) b.recordTurn(0, 0, 0);
}

test "Budget: concurrent turn bumps trip the cap once observed" {
    var b = Budget.init(.{ .turns = 250 });

    const producers: usize = 4;
    const per: u64 = 100;

    var threads: [producers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, bumpTurnsWorker, .{ &b, per });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, 400), b.snapshot().turns);
    try testing.expectEqual(ExceededAxis.turns, b.check());
}
