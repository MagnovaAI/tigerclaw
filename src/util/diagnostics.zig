//! Rolling diagnostics buffer.
//!
//! A bounded, in-memory ring buffer that captures startup and
//! runtime metrics for later inspection — a `tigerclaw status`
//! sub-command, an SSE status endpoint, or a crash dump can all
//! drain the same buffer without racing with the hot path.
//!
//! Goals:
//!
//!   * **Bounded memory**. Fixed capacity at construction. Pushes
//!     past capacity overwrite the oldest entry. This keeps the
//!     buffer useful during a long session without bleeding RAM.
//!   * **No allocation on push**. Every `Event` slot is inline;
//!     strings live in fixed-size arrays so pushing is O(1) and
//!     allocation-free. Callers pass `[]const u8` of any length,
//!     which we truncate (recording the original length) rather
//!     than allocate.
//!   * **Concurrency**. Pushes from any thread land behind a
//!     spinlock; readers (`snapshot`, `iter`) also take the lock.
//!     The critical section is two writes + one counter bump.
//!   * **Monotonic order**. Each event carries a monotonically
//!     increasing sequence number so a consumer can reassemble
//!     the true order across truncated captures.
//!
//! Non-goals:
//!
//!   * Anything resembling a full-fidelity log. The trace
//!     subsystem (`src/trace`) is for that. This buffer exists
//!     for short, high-signal records: "settings loaded",
//!     "sandbox selected = noop", "first-turn latency = 124 ms".

const std = @import("std");

/// Inline message capacity. 120 bytes fits most status lines
/// comfortably and leaves the whole `Event` at a cache-friendly
/// size (under 192 bytes).
pub const max_message_bytes: usize = 120;

/// Event severity/category. Fine-grained kinds are cheap — an
/// enum tag is one byte — and make filtering tractable.
pub const Kind = enum(u8) {
    /// Expected lifecycle events: "started", "config loaded".
    info,
    /// A metric sample: "startup_ms=24", "provider_latency_ms=…".
    metric,
    /// Degraded-but-working condition: "provider fallback fired".
    warn,
    /// Recoverable error that did not crash the process.
    err,
};

/// Fixed-size event record. No pointers outside the struct, so
/// copying a slice of events is `@memcpy`.
pub const Event = struct {
    /// Monotonic sequence number assigned at push. Unique
    /// per-buffer, wraps on `u64` overflow (absurd).
    seq: u64,
    /// Clock reading at push time (nanoseconds). Zero means
    /// "no clock was provided"; the buffer takes an optional
    /// clock to keep tests simple.
    timestamp_ns: i128,
    kind: Kind,
    /// Number of bytes actually written into `message_buf`. Never
    /// exceeds `max_message_bytes`; if the caller's message was
    /// longer, the value reflects the truncated length so a UI
    /// can render an ellipsis.
    message_len: u16,
    /// Original, pre-truncation length. Exposed so callers know
    /// whether truncation happened.
    original_len: u32,
    message_buf: [max_message_bytes]u8,

    pub fn message(self: *const Event) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn wasTruncated(self: *const Event) bool {
        return self.original_len > self.message_len;
    }
};

/// Minimal clock interface. `DiagnosticsBuffer` accepts an
/// optional `NowFn`; tests pass a counter, production passes the
/// harness clock. Kept as a simple function pointer rather than
/// a full vtable because the buffer does not need anything else
/// from a clock.
pub const NowFn = *const fn () i128;

pub const DiagnosticsBuffer = struct {
    /// Backing storage. Heap-allocated once at init; capacity is
    /// `slots.len`.
    slots: []Event,
    /// Next index to write into (circular). Always in
    /// `[0, slots.len)`.
    cursor: usize = 0,
    /// Total number of pushes ever seen. When `count < slots.len`
    /// the buffer has not yet wrapped; when it is larger, the
    /// oldest `count - slots.len` pushes are gone.
    count: u64 = 0,
    next_seq: u64 = 0,
    now_fn: ?NowFn = null,
    allocator: std.mem.Allocator,
    /// Tiny spinlock (same rationale as `cost/ledger.zig`). The
    /// protected region is short — two struct writes and a
    /// counter bump — so a futex would be overkill.
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        now_fn: ?NowFn,
    ) !DiagnosticsBuffer {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Event, capacity);
        // Zero the slots so an accidental early read is not UB.
        for (slots) |*s| s.* = .{
            .seq = 0,
            .timestamp_ns = 0,
            .kind = .info,
            .message_len = 0,
            .original_len = 0,
            .message_buf = undefined,
        };
        return .{
            .slots = slots,
            .allocator = allocator,
            .now_fn = now_fn,
        };
    }

    pub fn deinit(self: *DiagnosticsBuffer) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    fn lockIt(self: *DiagnosticsBuffer) void {
        while (true) {
            if (self.lock.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return;
            std.Thread.yield() catch {};
        }
    }

    fn unlockIt(self: *DiagnosticsBuffer) void {
        self.lock.store(false, .release);
    }

    /// Record an event. Returns the assigned sequence number so
    /// callers can correlate later records.
    pub fn push(self: *DiagnosticsBuffer, kind: Kind, msg: []const u8) u64 {
        self.lockIt();
        defer self.unlockIt();

        const idx = self.cursor;
        const slot = &self.slots[idx];
        slot.seq = self.next_seq;
        slot.kind = kind;
        slot.timestamp_ns = if (self.now_fn) |f| f() else 0;
        slot.original_len = @intCast(@min(msg.len, std.math.maxInt(u32)));
        const to_copy = @min(msg.len, max_message_bytes);
        @memcpy(slot.message_buf[0..to_copy], msg[0..to_copy]);
        slot.message_len = @intCast(to_copy);

        const assigned = self.next_seq;
        self.next_seq +%= 1;
        self.cursor = (idx + 1) % self.slots.len;
        self.count +%= 1;
        return assigned;
    }

    /// Number of events currently stored (never exceeds capacity).
    pub fn len(self: *DiagnosticsBuffer) usize {
        self.lockIt();
        defer self.unlockIt();
        return if (self.count < self.slots.len) @intCast(self.count) else self.slots.len;
    }

    /// Total pushes ever seen. Exposed for tests and for the
    /// "dropped N events" UI affordance: `dropped = total - len`.
    pub fn totalPushes(self: *DiagnosticsBuffer) u64 {
        self.lockIt();
        defer self.unlockIt();
        return self.count;
    }

    /// Write the stored events in chronological order into `out`.
    /// Returns the number of events written. `out.len` must be ≥
    /// `len()`; callers size the slice via the `len()` return.
    pub fn snapshotInto(self: *DiagnosticsBuffer, out: []Event) usize {
        self.lockIt();
        defer self.unlockIt();
        const count: usize = if (self.count < self.slots.len) @intCast(self.count) else self.slots.len;
        if (count == 0) return 0;

        const start: usize = if (self.count < self.slots.len)
            0
        else
            self.cursor;

        for (0..count) |i| {
            const src = (start + i) % self.slots.len;
            out[i] = self.slots[src];
        }
        return count;
    }

    /// Convenience: allocate + fill a chronological snapshot.
    /// Caller owns the returned slice.
    pub fn snapshot(self: *DiagnosticsBuffer, allocator: std.mem.Allocator) ![]Event {
        const n = self.len();
        const out = try allocator.alloc(Event, n);
        errdefer allocator.free(out);
        const written = self.snapshotInto(out);
        std.debug.assert(written == n);
        return out;
    }

    /// Discard every event, keeping capacity and sequence
    /// continuity. `next_seq` is preserved so a consumer
    /// reading pre-reset records still sees earlier numbers
    /// strictly before post-reset ones.
    pub fn clear(self: *DiagnosticsBuffer) void {
        self.lockIt();
        defer self.unlockIt();
        self.cursor = 0;
        self.count = 0;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "DiagnosticsBuffer: zero capacity is rejected" {
    try testing.expectError(
        error.InvalidCapacity,
        DiagnosticsBuffer.init(testing.allocator, 0, null),
    );
}

test "DiagnosticsBuffer: push then snapshot round-trips in order" {
    var b = try DiagnosticsBuffer.init(testing.allocator, 4, null);
    defer b.deinit();

    _ = b.push(.info, "first");
    _ = b.push(.metric, "second");
    _ = b.push(.warn, "third");

    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expectEqual(@as(u64, 3), b.totalPushes());

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqual(@as(usize, 3), snap.len);
    try testing.expectEqualStrings("first", snap[0].message());
    try testing.expectEqualStrings("second", snap[1].message());
    try testing.expectEqualStrings("third", snap[2].message());
    try testing.expectEqual(Kind.info, snap[0].kind);
    try testing.expectEqual(Kind.metric, snap[1].kind);
    try testing.expectEqual(Kind.warn, snap[2].kind);
}

test "DiagnosticsBuffer: overwriting preserves chronological order" {
    var b = try DiagnosticsBuffer.init(testing.allocator, 3, null);
    defer b.deinit();

    _ = b.push(.info, "a");
    _ = b.push(.info, "b");
    _ = b.push(.info, "c");
    _ = b.push(.info, "d"); // evicts "a"
    _ = b.push(.info, "e"); // evicts "b"

    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expectEqual(@as(u64, 5), b.totalPushes());

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqualStrings("c", snap[0].message());
    try testing.expectEqualStrings("d", snap[1].message());
    try testing.expectEqualStrings("e", snap[2].message());

    // Sequence numbers reflect the true push order, even after
    // eviction.
    try testing.expectEqual(@as(u64, 2), snap[0].seq);
    try testing.expectEqual(@as(u64, 3), snap[1].seq);
    try testing.expectEqual(@as(u64, 4), snap[2].seq);
}

test "DiagnosticsBuffer: messages longer than max are truncated but flagged" {
    var b = try DiagnosticsBuffer.init(testing.allocator, 2, null);
    defer b.deinit();

    var long_buf: [max_message_bytes + 32]u8 = undefined;
    @memset(&long_buf, 'x');

    _ = b.push(.info, &long_buf);
    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqual(max_message_bytes, snap[0].message().len);
    try testing.expect(snap[0].wasTruncated());
    try testing.expectEqual(@as(u32, max_message_bytes + 32), snap[0].original_len);
}

test "DiagnosticsBuffer: clock timestamps events when one is provided" {
    const Tick = struct {
        var n: i128 = 0;
        fn now() i128 {
            n += 100;
            return n;
        }
    };

    var b = try DiagnosticsBuffer.init(testing.allocator, 4, Tick.now);
    defer b.deinit();

    _ = b.push(.info, "first");
    _ = b.push(.info, "second");

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expect(snap[0].timestamp_ns < snap[1].timestamp_ns);
}

test "DiagnosticsBuffer: clear resets count but keeps sequence continuity" {
    var b = try DiagnosticsBuffer.init(testing.allocator, 4, null);
    defer b.deinit();

    _ = b.push(.info, "a");
    _ = b.push(.info, "b");
    b.clear();

    try testing.expectEqual(@as(usize, 0), b.len());

    const assigned = b.push(.info, "c");
    try testing.expectEqual(@as(u64, 2), assigned);

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings("c", snap[0].message());
}

test "DiagnosticsBuffer: concurrent pushes preserve totals" {
    var b = try DiagnosticsBuffer.init(testing.allocator, 1024, null);
    defer b.deinit();

    const per_thread: u32 = 200;
    const thread_count: usize = 8;

    const Worker = struct {
        fn run(buf: *DiagnosticsBuffer, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) _ = buf.push(.info, "x");
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &b, per_thread });
    }
    for (threads) |t| t.join();

    try testing.expectEqual(
        @as(u64, @as(u64, thread_count) * per_thread),
        b.totalPushes(),
    );
}
