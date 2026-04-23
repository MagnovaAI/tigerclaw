//! Channel abstraction: the vtable, message types, and errors that every
//! channel adapter (Telegram today, Slack / iMessage / etc. later) must
//! implement so the dispatch layer can treat them uniformly.
//!
//! Why an interface here: the runtime needs to fan inbound human messages
//! from many upstream services into a single dispatch pipeline, and fan
//! outbound agent replies back out. Keeping the surface small — one pull,
//! one push, one cancel-aware receive — means new adapters slot in without
//! changing the dispatcher.
//!
//! Thread model (locked):
//!   * One OS thread per enabled channel owns that channel's `receive`
//!     loop and is the sole caller of `receive` for its `Channel` value.
//!   * A single shared dispatch worker thread drains a mutex-guarded
//!     bounded FIFO of `InboundMessage` values produced by those
//!     receivers, and later invokes `send` on the appropriate channel.
//!   * Per-agent worker fan-out is intentionally deferred; the surface
//!     here does not presume it.
//!
//! Concurrency contract:
//!   * The vtable methods may be invoked from any thread, but a single
//!     `Channel` value's `send` and `receive` are NOT designed to run
//!     concurrently on the same instance. The channel manager ensures
//!     exclusive ownership per Channel.
//!   * `receive` implementations MUST observe `cancel` with
//!     `.acquire` ordering. The manager flips the flag with `.release`
//!     so any message buffered before cancellation is visible to the
//!     receiver when it wakes.

const std = @import("std");

/// Stable identifier for a concrete channel kind. Kept deliberately small
/// in v0.1.0; new adapters extend this enum as they land.
pub const ChannelId = enum {
    telegram,
};

pub const InboundMessage = struct {
    /// Stable opaque id from the upstream channel (Telegram update_id, etc.).
    /// Channel adapters guarantee monotonic ordering per (channel_id, conversation_key).
    upstream_id: u64,
    /// Stamped by the channel adapter via its vtable id(). The
    /// dispatch worker reads this to route to the right outbox
    /// partition. Default is `.telegram` because v0.1.0 has only one
    /// channel kind; kept explicit so a missing stamp surfaces as a
    /// compile error when a new kind joins the enum.
    channel_id: ChannelId = .telegram,
    /// Stamped by the channel manager: the name of the agent this
    /// binding belongs to. Borrowed from the agent registry arena,
    /// valid for the daemon's lifetime. The dispatch worker uses
    /// `(agent_name, channel_id, conversation_key)` to build the
    /// session key routed to the runner.
    agent_name: []const u8 = "",
    /// Routing key the dispatch layer maps to a session. Raw, URL-safe text;
    /// Telegram supplies the chat id formatted as decimal.
    conversation_key: []const u8,
    /// Optional thread/topic distinguisher within a conversation (Telegram
    /// message_thread_id, Slack thread_ts in the future). Null when the
    /// channel is single-threaded.
    thread_key: ?[]const u8 = null,
    /// Stable per-channel identifier of the human/sender. The dispatch
    /// layer rate-limits and allowlists on this. Borrowed; channel
    /// adapters keep it alive for the duration of the dispatch call.
    sender_id: []const u8,
    /// Raw text content. Empty for non-text messages until later commits
    /// extend the union; keep the surface small in v0.1.0.
    text: []const u8,
};

pub const OutboundMessage = struct {
    conversation_key: []const u8,
    thread_key: ?[]const u8 = null,
    text: []const u8,
};

pub const SendError = error{
    /// The remote API rejected the payload (4xx / validation failure).
    BadRequest,
    /// Auth failed (bad token, revoked) — operator must update config.
    Unauthorized,
    /// Channel-level rate limit hit; dispatch should back off and retry.
    RateLimited,
    /// Network / 5xx — caller decides whether to retry.
    TransportFailure,
};

pub const ReceiveError = error{
    Unauthorized,
    TransportFailure,
};

pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stable identifier so logs and metrics can disambiguate
        /// channels even when multiple adapters share the same kind.
        id: *const fn (ptr: *anyopaque) ChannelId,
        /// Push an outbound message to the upstream API. Synchronous —
        /// the outbox manages retries; channel impls do not loop.
        send: *const fn (ptr: *anyopaque, msg: OutboundMessage) SendError!void,
        /// Pull the next batch of inbound messages from the channel's
        /// long-poll. Blocks the caller's thread until at least one
        /// message arrives or the cancel flag flips.
        ///
        /// Caller-allocated `buf` is filled in order; returns the count
        /// of `buf` slots actually populated. A zero return means the
        /// cancel flag was observed before any message arrived.
        receive: *const fn (
            ptr: *anyopaque,
            buf: []InboundMessage,
            cancel: *const std.atomic.Value(bool),
        ) ReceiveError!usize,
        /// Release adapter-owned resources (HTTP client, polling state).
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn id(self: Channel) ChannelId {
        return self.vtable.id(self.ptr);
    }

    pub fn send(self: Channel, msg: OutboundMessage) SendError!void {
        return self.vtable.send(self.ptr, msg);
    }

    pub fn receive(
        self: Channel,
        buf: []InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) ReceiveError!usize {
        return self.vtable.receive(self.ptr, buf, cancel);
    }

    pub fn deinit(self: Channel) void {
        self.vtable.deinit(self.ptr);
    }
};

// --- tests -----------------------------------------------------------------

const FakeChannel = struct {
    id_calls: usize = 0,
    send_calls: usize = 0,
    receive_calls: usize = 0,
    deinit_calls: usize = 0,
    last_sent: ?OutboundMessage = null,
    fail_send: bool = false,
    canned: []const InboundMessage = &.{},

    fn channel(self: *FakeChannel) Channel {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn idFn(ptr: *anyopaque) ChannelId {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        self.id_calls += 1;
        return .telegram;
    }

    fn sendFn(ptr: *anyopaque, msg: OutboundMessage) SendError!void {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        self.send_calls += 1;
        self.last_sent = msg;
        if (self.fail_send) return SendError.BadRequest;
    }

    fn receiveFn(
        ptr: *anyopaque,
        buf: []InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) ReceiveError!usize {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        self.receive_calls += 1;
        if (cancel.load(.acquire)) return 0;
        const n = @min(buf.len, self.canned.len);
        for (0..n) |i| buf[i] = self.canned[i];
        return n;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        self.deinit_calls += 1;
    }

    const vt: Channel.VTable = .{
        .id = idFn,
        .send = sendFn,
        .receive = receiveFn,
        .deinit = deinitFn,
    };
};

test "Channel.id forwards to the vtable" {
    var fake: FakeChannel = .{};
    const ch = fake.channel();
    try std.testing.expectEqual(ChannelId.telegram, ch.id());
    try std.testing.expectEqual(@as(usize, 1), fake.id_calls);
}

test "Channel.send forwards payload and propagates BadRequest" {
    var fake: FakeChannel = .{};
    const ch = fake.channel();
    try ch.send(.{ .conversation_key = "c1", .text = "hello" });
    try std.testing.expectEqual(@as(usize, 1), fake.send_calls);
    try std.testing.expectEqualStrings("c1", fake.last_sent.?.conversation_key);
    try std.testing.expectEqualStrings("hello", fake.last_sent.?.text);

    fake.fail_send = true;
    try std.testing.expectError(
        SendError.BadRequest,
        ch.send(.{ .conversation_key = "c1", .text = "boom" }),
    );
}

test "Channel.receive returns populated count and respects cancel" {
    var fake: FakeChannel = .{};
    const msgs = [_]InboundMessage{
        .{
            .upstream_id = 42,
            .conversation_key = "c1",
            .sender_id = "u1",
            .text = "hi",
        },
    };
    fake.canned = &msgs;

    var buf: [4]InboundMessage = undefined;
    var cancel: std.atomic.Value(bool) = .init(false);
    const ch = fake.channel();

    const got = try ch.receive(&buf, &cancel);
    try std.testing.expectEqual(@as(usize, 1), got);
    try std.testing.expectEqual(@as(u64, 42), buf[0].upstream_id);

    cancel.store(true, .release);
    const got2 = try ch.receive(&buf, &cancel);
    try std.testing.expectEqual(@as(usize, 0), got2);
}

test "Channel.deinit is invoked exactly once" {
    var fake: FakeChannel = .{};
    const ch = fake.channel();
    ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_calls);
}
