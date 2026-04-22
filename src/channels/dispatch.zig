//! Bounded inbound FIFO with drop-oldest backpressure.
//!
//! Every channel adapter (Telegram poller, Discord websocket, ...)
//! pushes `spec.InboundMessage` values into this queue from its own
//! thread. A single dispatch worker drains the queue and hands each
//! message to the agent runner.
//!
//! Design choices worth calling out:
//!
//! * **Value storage, not pointers.** `enqueue` copies the message
//!   struct. Channel threads are free to release the source memory
//!   as soon as the call returns. This keeps lifetime reasoning
//!   local to the adapter and avoids the queue inheriting a free
//!   list it never signed up for. Any pointer fields `spec`
//!   eventually adds must either point at memory that outlives
//!   dequeue or be explicitly transferred in ownership.
//!
//! * **Drop-oldest backpressure.** If the queue is full the oldest
//!   entry is overwritten and `dropped` is bumped. The gateway
//!   would rather skip a stale Telegram update than block the
//!   poller that produced it — a blocked poller stalls the whole
//!   channel, and recovery is messier than losing one update.
//!
//! * **Spinlock, not `std.Io.Mutex`.** Zig 0.16's `std.Io.Mutex`
//!   demands an `Io` handle on every lock/unlock, which would
//!   contaminate every channel thread that wants to enqueue. The
//!   ring-buffer critical sections are a handful of instructions,
//!   so a yielding test-and-set lock (same pattern used in
//!   `src/cost/ledger.zig`) is both simpler and enough. The
//!   consumer blocks on an empty queue by releasing the lock and
//!   yielding rather than waiting on a condvar — again because
//!   `std.Io.Condition.wait` requires `Io`.

const std = @import("std");

const spec = @import("channels_spec");

/// Tiny yielding spinlock. See the `Spinlock` in
/// `src/cost/ledger.zig` for the rationale; this copy is kept local
/// so `channels` does not reach into a peer subsystem.
const Spinlock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *Spinlock) void {
        while (true) {
            if (self.state.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return;
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Spinlock) void {
        self.state.store(false, .release);
    }
};

pub const Dispatch = struct {
    pub const default_capacity: usize = 256;

    pub const Stats = struct {
        enqueued: u64 = 0,
        dropped: u64 = 0,
        drained: u64 = 0,
    };

    allocator: std.mem.Allocator,
    buffer: []spec.InboundMessage,
    head: usize = 0,
    len: usize = 0,

    mutex: Spinlock = .{},

    enqueued: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    drained: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Dispatch {
        std.debug.assert(capacity > 0);
        const buffer = try allocator.alloc(spec.InboundMessage, capacity);
        return .{
            .allocator = allocator,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Dispatch) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Push a message onto the queue. Returns `true` when the
    /// message landed in free space; returns `false` when the queue
    /// was full and the oldest entry was evicted to make room.
    /// Never blocks the caller.
    pub fn enqueue(self: *Dispatch, msg: spec.InboundMessage) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cap = self.buffer.len;
        var accepted_cleanly = true;
        if (self.len == cap) {
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            _ = self.dropped.fetchAdd(1, .monotonic);
            accepted_cleanly = false;
        }

        const tail = (self.head + self.len) % cap;
        self.buffer[tail] = msg;
        self.len += 1;
        _ = self.enqueued.fetchAdd(1, .monotonic);
        return accepted_cleanly;
    }

    /// Pop the next message, waiting if the queue is empty. Returns
    /// `null` once `cancel.load(.acquire)` is observed true while
    /// the queue is empty. The wait is a yield-poll loop rather
    /// than a condvar because `std.Io.Condition` requires an `Io`
    /// handle we would otherwise have to plumb through every
    /// caller.
    pub fn dequeue(
        self: *Dispatch,
        cancel: *const std.atomic.Value(bool),
    ) ?spec.InboundMessage {
        while (true) {
            self.mutex.lock();
            if (self.len > 0) {
                const msg = self.buffer[self.head];
                self.head = (self.head + 1) % self.buffer.len;
                self.len -= 1;
                _ = self.drained.fetchAdd(1, .monotonic);
                self.mutex.unlock();
                return msg;
            }
            self.mutex.unlock();

            if (cancel.load(.acquire)) return null;
            std.Thread.yield() catch {};
        }
    }

    pub fn stats(self: *const Dispatch) Stats {
        return .{
            .enqueued = self.enqueued.load(.monotonic),
            .dropped = self.dropped.load(.monotonic),
            .drained = self.drained.load(.monotonic),
        };
    }

    pub fn beginTurn(self: *Dispatch) void {
        _ = self.in_flight.fetchAdd(1, .acq_rel);
    }

    pub fn endTurn(self: *Dispatch) void {
        const prev = self.in_flight.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    pub fn inFlight(self: *const Dispatch) u32 {
        return self.in_flight.load(.acquire);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Construct a test InboundMessage with only upstream_id meaningfully
/// varied; the rest are placeholders — tests assert identity via
/// upstream_id alone.
fn testMsg(upstream_id: u64) spec.InboundMessage {
    return .{
        .upstream_id = upstream_id,
        .conversation_key = "t",
        .sender_id = "u",
        .text = "",
    };
}

test "enqueue then dequeue round-trips a message" {
    var q = try Dispatch.init(testing.allocator, 8);
    defer q.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    try testing.expect(q.enqueue(testMsg(42)));
    const got = q.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u64, 42), got.upstream_id);

    const s = q.stats();
    try testing.expectEqual(@as(u64, 1), s.enqueued);
    try testing.expectEqual(@as(u64, 1), s.drained);
    try testing.expectEqual(@as(u64, 0), s.dropped);
}

test "full queue drops oldest and keeps the most recent N" {
    var q = try Dispatch.init(testing.allocator, 4);
    defer q.deinit();

    var cancel = std.atomic.Value(bool).init(false);

    try testing.expect(q.enqueue(testMsg(1)));
    try testing.expect(q.enqueue(testMsg(2)));
    try testing.expect(q.enqueue(testMsg(3)));
    try testing.expect(q.enqueue(testMsg(4)));
    // These two overflow: the oldest entry is evicted and the
    // return value reports that eviction happened.
    try testing.expect(!q.enqueue(testMsg(5)));
    try testing.expect(!q.enqueue(testMsg(6)));

    var seen: [4]u64 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const m = q.dequeue(&cancel) orelse return error.TestUnexpectedNull;
        seen[i] = m.upstream_id;
    }

    try testing.expectEqualSlices(u64, &.{ 3, 4, 5, 6 }, &seen);
    try testing.expectEqual(@as(u64, 2), q.stats().dropped);
}

test "dequeue returns null promptly when cancel is set" {
    var q = try Dispatch.init(testing.allocator, 4);
    defer q.deinit();

    var cancel = std.atomic.Value(bool).init(true);
    try testing.expect(q.dequeue(&cancel) == null);
}

const ProducerCtx = struct {
    q: *Dispatch,
    start: u64,
    count: u64,
};

fn producerMain(ctx: *ProducerCtx) void {
    var i: u64 = 0;
    while (i < ctx.count) : (i += 1) {
        _ = ctx.q.enqueue(testMsg(ctx.start + i));
    }
}

test "4 producers x 100 messages — no message lost" {
    const per_producer: u64 = 100;
    const producers: usize = 4;
    const total: u64 = per_producer * @as(u64, producers);

    // Capacity chosen generously so drop-oldest never kicks in and
    // we can assert every `upstream_id` was delivered.
    var q = try Dispatch.init(testing.allocator, 1024);
    defer q.deinit();

    var ctxs: [producers]ProducerCtx = undefined;
    var threads: [producers]std.Thread = undefined;
    var p: usize = 0;
    while (p < producers) : (p += 1) {
        ctxs[p] = .{
            .q = &q,
            .start = @as(u64, p) * per_producer,
            .count = per_producer,
        };
        threads[p] = try std.Thread.spawn(.{}, producerMain, .{&ctxs[p]});
    }

    var cancel = std.atomic.Value(bool).init(false);
    var sum: u64 = 0;
    var received: u64 = 0;
    while (received < total) {
        const m = q.dequeue(&cancel) orelse return error.TestUnexpectedNull;
        sum += m.upstream_id;
        received += 1;
    }

    for (&threads) |t| t.join();

    // 0 + 1 + ... + (total - 1).
    const expected_sum = (total * (total - 1)) / 2;
    try testing.expectEqual(expected_sum, sum);
    try testing.expectEqual(@as(u64, 0), q.stats().dropped);
    try testing.expectEqual(total, q.stats().enqueued);
    try testing.expectEqual(total, q.stats().drained);
}

test "beginTurn and endTurn round-trip inFlight" {
    var q = try Dispatch.init(testing.allocator, 4);
    defer q.deinit();

    try testing.expectEqual(@as(u32, 0), q.inFlight());
    q.beginTurn();
    q.beginTurn();
    try testing.expectEqual(@as(u32, 2), q.inFlight());
    q.endTurn();
    try testing.expectEqual(@as(u32, 1), q.inFlight());
    q.endTurn();
    try testing.expectEqual(@as(u32, 0), q.inFlight());
}
