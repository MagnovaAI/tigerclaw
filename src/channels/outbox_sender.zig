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

pub const Sender = struct {
    io: std.Io,
    manager: *manager_mod.Manager,
    outbox: *outbox_mod.Outbox,
    channel_id: spec.ChannelId,
    poll_interval_ns: u64 = 200 * std.time.ns_per_ms,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

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

    pub fn start(self: *Sender) std.Thread.SpawnError!void {
        if (self.thread != null) return;
        self.cancel.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Sender) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
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
                };
                continue;
            },
            error.RateLimited, error.TransportFailure => {
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
        };
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("../clock.zig");
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
