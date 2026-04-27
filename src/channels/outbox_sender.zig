//! Outbox sender — drains the outbox and delivers to channel adapters.
//!
//! Pairs with `dispatch_worker.zig`: the worker writes replies into
//! the outbox JSONL log, and this module reads them out and calls
//! `channel.send()` for real delivery. Splitting append and deliver
//! across two threads means a slow Telegram send cannot stall the
//! dispatch path, and a crash between append and send leaves the
//! record intact on disk (to be retried on restart).
//!
//! # Threading
//!
//! One sender thread per channel kind. v0.1.0 has `.telegram` only.
//! The thread wakes every `poll_interval_ns`, opens a cursor, walks
//! every due record, and either acks (send succeeded) or records a
//! failure with exponential backoff (send errored).
//!
//! # Binding lookup
//!
//! Which adapter does a given record flow through? v0.1.0 ships
//! single-agent per channel kind, so a linear scan of the manager's
//! entries for the first binding with `channel.id() == our kind`
//! is enough. Multi-agent-per-channel-kind needs per-agent outbox
//! partitioning; that's a later ticket.

const std = @import("std");

const manager_mod = @import("manager.zig");
const outbox_mod = @import("outbox.zig");
const spec = @import("channels_spec");

const log = std.log.scoped(.outbox_sender);

fn threadKey(value: ?[]const u8) []const u8 {
    return value orelse "-";
}

pub const Sender = struct {
    io: std.Io,
    manager: *manager_mod.Manager,
    outbox: *outbox_mod.Outbox,
    channel_id: spec.ChannelId,
    poll_interval_ns: u64 = 200 * std.time.ns_per_ms,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Record ids whose on-disk ack persistence failed. Kept in
    /// process memory so we don't re-send the same reply every
    /// poll pass while the ack path is broken. Bounded at a small
    /// size — once we run out of slots new failures just retry.
    /// Survives only for the sender's lifetime; a daemon restart
    /// will see the unacked records and retry once (acceptable).
    failed_acks: std.ArrayList([]u8) = .empty,
    failed_allocator: ?std.mem.Allocator = null,

    pub fn init(
        io: std.Io,
        manager: *manager_mod.Manager,
        outbox: *outbox_mod.Outbox,
        channel_id: spec.ChannelId,
    ) Sender {
        return .{
            .io = io,
            .manager = manager,
            .outbox = outbox,
            .channel_id = channel_id,
        };
    }

    /// Attach an allocator for the failed-ack dedupe list. Called
    /// from start(). Separate from init() so the struct can be
    /// constructed without an allocator on the hot path.
    fn ensureFailedAcksAllocator(self: *Sender) void {
        if (self.failed_allocator == null) self.failed_allocator = self.outbox.allocator;
    }

    /// Record an id whose ack persistence failed so subsequent drain
    /// passes skip it instead of re-delivering forever. Bounded at
    /// 1024 slots — new failures silently drop once full (we'd
    /// rather re-send than OOM).
    fn rememberFailedAck(self: *Sender, id: []const u8) void {
        self.ensureFailedAcksAllocator();
        const alloc = self.failed_allocator orelse return;
        if (self.failed_acks.items.len >= 1024) return;
        const dup = alloc.dupe(u8, id) catch return;
        self.failed_acks.append(alloc, dup) catch alloc.free(dup);
    }

    fn hasFailedAck(self: *const Sender, id: []const u8) bool {
        for (self.failed_acks.items) |f| {
            if (std.mem.eql(u8, f, id)) return true;
        }
        return false;
    }

    pub fn start(self: *Sender) std.Thread.SpawnError!void {
        if (self.thread != null) return;
        self.cancel.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        log.info("outbox sender started channel={s}", .{@tagName(self.channel_id)});
    }

    pub fn stop(self: *Sender) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.failed_allocator) |alloc| {
            for (self.failed_acks.items) |f| alloc.free(f);
            self.failed_acks.deinit(alloc);
        }
        log.info("outbox sender stopped channel={s}", .{@tagName(self.channel_id)});
    }
};

fn loop(self: *Sender) void {
    while (!self.cancel.load(.acquire)) {
        // Grab whichever agent currently owns this channel kind. A
        // cold manager (no bindings yet) means nothing to send.
        const ch_opt = firstBinding(self.manager, self.channel_id);
        if (ch_opt) |ch| {
            drainOnce(self, ch) catch |err| {
                log.warn("outbox: drain failed for {s}: {s}", .{
                    @tagName(self.channel_id),
                    @errorName(err),
                });
            };
        }

        // Sleep between passes. Small enough that a reply feels
        // immediate, large enough that an idle daemon doesn't burn
        // CPU opening cursors.
        std.Io.sleep(
            self.io,
            std.Io.Duration.fromNanoseconds(@intCast(self.poll_interval_ns)),
            .awake,
        ) catch return;
    }
}

fn firstBinding(
    manager: *manager_mod.Manager,
    channel_id: spec.ChannelId,
) ?spec.Channel {
    // Manager doesn't expose entries publicly; we rely on `get` with
    // a known agent name. To keep v0.1.0 simple, scan the agent name
    // slot on each entry through a cheap helper. If this becomes hot
    // we promote to a proper index.
    for (manager.entries.items) |e| {
        if (e.channel.id() == channel_id) return e.channel;
    }
    return null;
}

fn drainOnce(self: *Sender, ch: spec.Channel) !void {
    var cursor = try self.outbox.cursor(self.channel_id);
    defer cursor.deinit();

    while (true) {
        const pending = (try cursor.next()) orelse return;

        // Skip records whose ack persistence previously failed. The
        // user-visible message already landed on the channel; the
        // only unfinished work is flipping the on-disk ack bit, and
        // retrying the send would duplicate. Data loss on daemon
        // restart is preferable to duplicated delivery.
        if (self.hasFailedAck(pending.id)) continue;

        log.info("outbound attempt channel={s} record_id={s} conversation={s} thread={s} attempts={d} next_due_unix_ms={d} text_bytes={d}", .{
            @tagName(self.channel_id),
            pending.id,
            pending.conversation_key,
            threadKey(pending.thread_key),
            pending.attempts,
            pending.next_due_unix_ms,
            pending.text.len,
        });

        const sent = ch.send(.{
            .conversation_key = pending.conversation_key,
            .thread_key = pending.thread_key,
            .text = pending.text,
        });

        sent catch |err| switch (err) {
            error.Unauthorized, error.BadRequest => {
                // Non-retryable — acking keeps the outbox moving.
                // Losing one malformed reply is better than wedging
                // every subsequent reply behind it.
                log.warn("outbox: non-retryable {s}; acking and moving on", .{@errorName(err)});
                cursor.ack(pending.id) catch |ack_err| {
                    log.warn("outbox: ack after fatal failed: {s}", .{@errorName(ack_err)});
                    self.rememberFailedAck(pending.id);
                };
                continue;
            },
            error.RateLimited, error.TransportFailure => {
                log.warn("outbound retry channel={s} record_id={s} conversation={s} thread={s} err={s} attempts={d}", .{
                    @tagName(self.channel_id),
                    pending.id,
                    pending.conversation_key,
                    threadKey(pending.thread_key),
                    @errorName(err),
                    pending.attempts + 1,
                });
                // Retryable — bump backoff and move on. The next
                // drainOnce pass will retry once next_due_unix_ms
                // is in the past.
                outbox_mod.recordFailure(self.outbox, self.channel_id, pending.id) catch |fail_err| {
                    log.warn("outbox: recordFailure failed: {s}", .{@errorName(fail_err)});
                };
                continue;
            },
        };

        cursor.ack(pending.id) catch |err| {
            log.warn("outbox: ack failed after successful send: {s}", .{@errorName(err)});
            self.rememberFailedAck(pending.id);
        };
        log.info("outbound sent channel={s} record_id={s} conversation={s} thread={s} text_bytes={d} attempts={d}", .{
            @tagName(self.channel_id),
            pending.id,
            pending.conversation_key,
            threadKey(pending.thread_key),
            pending.text.len,
            pending.attempts,
        });
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock");
const dispatch_mod = @import("dispatch.zig");

const FakeChannel = struct {
    sent_count: std.atomic.Value(u32) = .init(0),
    last_text: std.array_list.Aligned(u8, null) = .empty,
    allocator: std.mem.Allocator,
    fail_kind: ?spec.SendError = null,

    fn channel(self: *FakeChannel) spec.Channel {
        return .{ .ptr = self, .vtable = &vt };
    }
    fn idFn(_: *anyopaque) spec.ChannelId {
        return .telegram;
    }
    fn sendFn(ptr: *anyopaque, msg: spec.OutboundMessage) spec.SendError!void {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        if (self.fail_kind) |e| return e;
        _ = self.sent_count.fetchAdd(1, .acq_rel);
        self.last_text.clearRetainingCapacity();
        self.last_text.appendSlice(self.allocator, msg.text) catch return error.TransportFailure;
    }
    fn receiveFn(_: *anyopaque, _: []spec.InboundMessage, _: *const std.atomic.Value(bool)) spec.ReceiveError!usize {
        return 0;
    }
    fn deinitFn(_: *anyopaque) void {}
    const vt: spec.Channel.VTable = .{
        .id = idFn,
        .send = sendFn,
        .receive = receiveFn,
        .deinit = deinitFn,
    };
};

test "sender: drains one outbox record → channel.send → ack" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var outbox = try outbox_mod.Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    defer outbox.deinit();

    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 4);
    defer dispatch.deinit();
    var mgr = manager_mod.Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    var fake: FakeChannel = .{ .allocator = testing.allocator };
    defer fake.last_text.deinit(testing.allocator);
    try mgr.add("tiger", fake.channel());

    const id = try outbox.append(.telegram, .{ .conversation_key = "chat-1", .text = "hello" });
    testing.allocator.free(id);

    var sender = Sender.init(testing.io, &mgr, &outbox, .telegram);
    sender.poll_interval_ns = 10 * std.time.ns_per_ms;
    try sender.start();
    defer sender.stop();

    var waited_ns: u64 = 0;
    while (fake.sent_count.load(.acquire) == 0 and waited_ns < 2_000_000_000) : (waited_ns += 5_000_000) {
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    try testing.expect(fake.sent_count.load(.acquire) == 1);
    try testing.expectEqualStrings("hello", fake.last_text.items);

    // After the sender acks, the cursor should show no pending.
    waited_ns = 0;
    while (waited_ns < 1_000_000_000) : (waited_ns += 5_000_000) {
        var cur = try outbox.cursor(.telegram);
        defer cur.deinit();
        if ((try cur.next()) == null) return;
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(5_000_000), .awake) catch {};
    }
    return error.TestOutboxNeverDrained;
}
