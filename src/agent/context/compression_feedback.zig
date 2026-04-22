//! Compression feedback loop.
//!
//! Each compaction pass produces a before/after message count and
//! estimated token delta. The feedback record lets the context
//! engine tune how aggressive the next pass should be: if a pass
//! dropped 40 % of the history but saved only 5 % of the tokens,
//! the strategy is probably wrong for this workload (e.g. the
//! trailing tool results are the heavy ones, not the earliest
//! user turns).
//!
//! Scope for this commit: just the record + a ring of recent
//! results the engine can inspect. The adaptive strategy that
//! consumes it lands with the bench runner.

const std = @import("std");

pub const Record = struct {
    /// Messages in history before the pass.
    before_messages: u32,
    /// Messages after the pass.
    after_messages: u32,
    /// Estimated prompt tokens before the pass.
    before_tokens: u32,
    /// Estimated prompt tokens after the pass.
    after_tokens: u32,
    /// How many hints were synthesised during the pass.
    hints_added: u32,

    /// Fraction of messages removed (0..100, integer %).
    pub fn messagePctRemoved(self: Record) u32 {
        if (self.before_messages == 0) return 0;
        const removed = self.before_messages - @min(self.before_messages, self.after_messages);
        return @intCast(@as(u64, removed) * 100 / self.before_messages);
    }

    /// Fraction of tokens saved (0..100, integer %).
    pub fn tokenPctSaved(self: Record) u32 {
        if (self.before_tokens == 0) return 0;
        const saved = self.before_tokens - @min(self.before_tokens, self.after_tokens);
        return @intCast(@as(u64, saved) * 100 / self.before_tokens);
    }

    /// A pass is "good" when it saved materially more tokens than
    /// it dropped messages — the compactor kept the heavy content
    /// and spilled the noise.
    pub fn wasEffective(self: Record) bool {
        return self.tokenPctSaved() >= self.messagePctRemoved();
    }
};

/// Fixed-size ring of recent compaction outcomes. Not thread-safe;
/// the engine is called from the agent loop on one thread.
pub const Log = struct {
    pub const capacity: usize = 16;
    slots: [capacity]Record = undefined,
    cursor: usize = 0,
    count: usize = 0,

    pub fn push(self: *Log, r: Record) void {
        self.slots[self.cursor] = r;
        self.cursor = (self.cursor + 1) % capacity;
        if (self.count < capacity) self.count += 1;
    }

    pub fn recent(self: *const Log) []const Record {
        // The ring is not sorted into chronological order; we only
        // promise "the most recent N up to `count`". A consumer
        // that cares about order can rotate after copying.
        return self.slots[0..self.count];
    }

    pub fn len(self: *const Log) usize {
        return self.count;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Record.messagePctRemoved / tokenPctSaved / wasEffective" {
    const r = Record{
        .before_messages = 10,
        .after_messages = 4,
        .before_tokens = 1_000,
        .after_tokens = 200,
        .hints_added = 3,
    };
    try testing.expectEqual(@as(u32, 60), r.messagePctRemoved());
    try testing.expectEqual(@as(u32, 80), r.tokenPctSaved());
    try testing.expect(r.wasEffective());

    const bad = Record{
        .before_messages = 10,
        .after_messages = 6,
        .before_tokens = 1_000,
        .after_tokens = 950,
        .hints_added = 0,
    };
    try testing.expect(!bad.wasEffective());
}

test "Log: push wraps at capacity" {
    var log = Log{};
    var i: u32 = 0;
    while (i < Log.capacity + 5) : (i += 1) {
        log.push(.{ .before_messages = 0, .after_messages = 0, .before_tokens = i, .after_tokens = 0, .hints_added = 0 });
    }
    try testing.expectEqual(Log.capacity, log.len());
}
