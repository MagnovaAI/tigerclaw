//! Telegram channel — vtable adapter that wires the Bot API client into
//! the generic channel dispatch surface.
//!
//! This layer translates between two conventions:
//!
//!   * The channel spec speaks in strings (`conversation_key`,
//!     `thread_key`, `sender_id`) so the dispatcher can stay channel-
//!     agnostic.
//!   * The Telegram API speaks in signed 64-bit integers for chat ids,
//!     message thread ids, and user ids.
//!
//! The adapter formats ints into decimal strings on receive and parses
//! them back on send. Anything that cannot be parsed is surfaced as
//! `BadRequest` — we refuse to guess.
//!
//! ## String lifetimes
//!
//! `InboundMessage` borrows its string fields; the spec says "channel
//! adapters keep it alive for the duration of the dispatch call." We
//! allocate those strings via `self.allocator` and expose
//! `freeInbound` so the manager can release them once dispatch is
//! done. The strings would otherwise leak the moment the receive call
//! returned — an allocator-backed approach keeps ownership explicit
//! without introducing a per-channel arena.

const std = @import("std");
const spec = @import("channels_spec");
const api = @import("api.zig");

pub const TelegramChannel = struct {
    allocator: std.mem.Allocator,
    bot: *api.Bot,
    /// Last update_id observed; the next poll requests
    /// `next_offset + 1` so Telegram discards already-delivered
    /// updates. Left null until the first successful batch.
    next_offset: ?i64 = null,

    /// Long-poll timeout handed to Telegram. 30s matches the upstream
    /// recommendation — short enough that a cancel flag is noticed
    /// within a reasonable window, long enough that a quiet bot doesn't
    /// hammer the endpoint.
    poll_timeout_s: u32 = 30,

    pub fn init(allocator: std.mem.Allocator, bot: *api.Bot) TelegramChannel {
        return .{ .allocator = allocator, .bot = bot };
    }

    pub fn channel(self: *TelegramChannel) spec.Channel {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: spec.Channel.VTable = .{
        .id = idFn,
        .send = sendFn,
        .receive = receiveFn,
        .deinit = deinitFn,
    };

    fn idFn(_: *anyopaque) spec.ChannelId {
        return .telegram;
    }

    fn sendFn(ptr: *anyopaque, msg: spec.OutboundMessage) spec.SendError!void {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));

        const chat_id = std.fmt.parseInt(i64, msg.conversation_key, 10) catch
            return spec.SendError.BadRequest;

        // `thread_key` is the OutboundMessage field most closely aligned
        // with Telegram's `reply_to_message_id`: the dispatcher treats
        // both as "thread continuation" hints, and Telegram has no
        // separate notion of a stable thread identifier in private /
        // group chats. Topic supergroups have a real thread id but the
        // outbox doesn't distinguish them in v0.1.0.
        const reply_to: ?i64 = if (msg.thread_key) |tk|
            (std.fmt.parseInt(i64, tk, 10) catch return spec.SendError.BadRequest)
        else
            null;

        _ = self.bot.sendMessage(chat_id, msg.text, reply_to) catch |err| switch (err) {
            // `OutOfMemory` is collapsed into TransportFailure: the spec
            // surface doesn't expose OOM (it's a local-resource issue,
            // not a channel-protocol one) and the manager retries
            // transport failures with backoff.
            error.OutOfMemory => return spec.SendError.TransportFailure,
            error.BadRequest => return spec.SendError.BadRequest,
            error.Unauthorized => return spec.SendError.Unauthorized,
            error.RateLimited => return spec.SendError.RateLimited,
            error.TransportFailure => return spec.SendError.TransportFailure,
        };
    }

    fn receiveFn(
        ptr: *anyopaque,
        buf: []spec.InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) spec.ReceiveError!usize {
        const self: *TelegramChannel = @ptrCast(@alignCast(ptr));

        while (true) {
            if (cancel.load(.acquire)) return 0;

            const offset = if (self.next_offset) |o| o + 1 else null;
            var updates_opt = self.bot.getUpdates(offset, self.poll_timeout_s, self.allocator) catch |err| {
                // `getUpdates` returns an anyerror; the Bot collapses
                // transport/parse failures into error.TransportFailure
                // and we map everything else the same way — the
                // receiver thread has no meaningful recovery beyond
                // retry-with-backoff, which the manager owns.
                return switch (err) {
                    error.OutOfMemory => spec.ReceiveError.TransportFailure,
                    else => spec.ReceiveError.TransportFailure,
                };
            };

            if (cancel.load(.acquire)) {
                if (updates_opt) |*u| u.deinit();
                return 0;
            }

            var updates = updates_opt orelse continue;
            defer updates.deinit();

            var written: usize = 0;
            var highest: i64 = self.next_offset orelse std.math.minInt(i64);

            for (updates.items) |upd| {
                if (upd.update_id > highest) highest = upd.update_id;
                if (written >= buf.len) break;
                const msg = upd.message orelse continue;
                const text = msg.text orelse continue;

                const inbound = self.buildInbound(upd.update_id, msg, text) catch
                    return spec.ReceiveError.TransportFailure;
                buf[written] = inbound;
                written += 1;
            }

            // Advance past everything in this batch even if we dropped
            // some (non-text, buf-full). Telegram re-delivers anything
            // we don't ack via offset, so swallowing non-text here is
            // required — otherwise the poll would re-pull them forever.
            self.next_offset = highest;

            if (written > 0) return written;
            // Empty batch (all non-text or none at all) — loop again so
            // the caller isn't woken just to re-call us.
        }
    }

    fn buildInbound(
        self: *TelegramChannel,
        update_id: i64,
        msg: api.Message,
        text: []const u8,
    ) !spec.InboundMessage {
        var conv_buf: [32]u8 = undefined;
        const conv_slice = std.fmt.bufPrint(&conv_buf, "{d}", .{msg.chat.id}) catch unreachable;
        const conv = try self.allocator.dupe(u8, conv_slice);
        errdefer self.allocator.free(conv);

        const thread: ?[]const u8 = if (msg.message_thread_id) |t| blk: {
            var tbuf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&tbuf, "{d}", .{t}) catch unreachable;
            break :blk try self.allocator.dupe(u8, slice);
        } else null;
        errdefer if (thread) |t| self.allocator.free(t);

        const sender: []const u8 = if (msg.from) |u| blk: {
            var sbuf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&sbuf, "{d}", .{u.id}) catch unreachable;
            break :blk try self.allocator.dupe(u8, slice);
        } else try self.allocator.dupe(u8, "anonymous");
        errdefer self.allocator.free(sender);

        const text_owned = try self.allocator.dupe(u8, text);

        return .{
            .upstream_id = @intCast(@max(update_id, 0)),
            .conversation_key = conv,
            .thread_key = thread,
            .sender_id = sender,
            .text = text_owned,
        };
    }

    /// Releases the strings allocated for `msg` by a prior `receive`
    /// call. The manager invokes this after it has finished dispatching
    /// the message to the agent runner — doing it sooner would free
    /// slices the agent is still reading.
    pub fn freeInbound(self: *TelegramChannel, msg: spec.InboundMessage) void {
        self.allocator.free(msg.conversation_key);
        if (msg.thread_key) |t| self.allocator.free(t);
        self.allocator.free(msg.sender_id);
        self.allocator.free(msg.text);
    }

    fn deinitFn(_: *anyopaque) void {}
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const FakeServerArgs = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
    accepted: *std.atomic.Value(bool),
};

fn fakeServerThread(args: *FakeServerArgs) void {
    var stream = args.server.accept(args.io) catch return;
    defer stream.close(args.io);

    var read_buf: [8192]u8 = undefined;
    var write_buf: [2048]u8 = undefined;
    var s_reader = stream.reader(args.io, &read_buf);
    var s_writer = stream.writer(args.io, &write_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;
    args.accepted.store(true, .release);
    request.respond(args.body, .{
        .status = args.status,
        .keep_alive = false,
    }) catch return;
}

fn spawnFakeServer(
    server: *std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
    accepted: *std.atomic.Value(bool),
) !std.Thread {
    const args = try testing.allocator.create(FakeServerArgs);
    args.* = .{
        .io = testing.io,
        .server = server,
        .status = status,
        .body = body,
        .accepted = accepted,
    };
    return try std.Thread.spawn(.{}, fakeOwned, .{args});
}

fn fakeOwned(args: *FakeServerArgs) void {
    fakeServerThread(args);
    testing.allocator.destroy(args);
}

fn makeBot(base_url: []const u8) api.Bot {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .token = "test-token",
        .base_url = base_url,
    };
}

test "telegram channel: id returns .telegram" {
    var bot = makeBot("http://127.0.0.1:1");
    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();
    try testing.expectEqual(spec.ChannelId.telegram, ch.id());
}

test "telegram channel: send happy path parses message_id" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var accepted: std.atomic.Value(bool) = .init(false);
    const thread = try spawnFakeServer(
        &server,
        .ok,
        \\{"ok":true,"result":{"message_id":42,"chat":{"id":1,"type":"private"}}}
    ,
        &accepted,
    );
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});
    var bot = makeBot(base);

    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();
    try ch.send(.{ .conversation_key = "1", .text = "hello" });
}

test "telegram channel: send 401 maps to Unauthorized" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var accepted: std.atomic.Value(bool) = .init(false);
    const thread = try spawnFakeServer(
        &server,
        .unauthorized,
        "{\"ok\":false,\"description\":\"bad token\"}",
        &accepted,
    );
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});
    var bot = makeBot(base);

    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();
    try testing.expectError(
        spec.SendError.Unauthorized,
        ch.send(.{ .conversation_key = "1", .text = "hi" }),
    );
}

test "telegram channel: send rejects unparseable conversation_key" {
    var bot = makeBot("http://127.0.0.1:1");
    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();
    try testing.expectError(
        spec.SendError.BadRequest,
        ch.send(.{ .conversation_key = "not-a-number", .text = "hi" }),
    );
}

test "telegram channel: receive populates buf from getUpdates response" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var accepted: std.atomic.Value(bool) = .init(false);
    const thread = try spawnFakeServer(
        &server,
        .ok,
        \\{"ok":true,"result":[
        \\  {"update_id":10,"message":{"message_id":1,"from":{"id":77,"username":"a"},"chat":{"id":-100,"type":"group"},"text":"hello"}},
        \\  {"update_id":11,"callback_query":{"id":"x"}},
        \\  {"update_id":12,"message":{"message_id":2,"from":{"id":78},"chat":{"id":5,"type":"private"},"message_thread_id":99,"text":"world"}}
        \\]}
    ,
        &accepted,
    );
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});
    var bot = makeBot(base);

    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();

    var buf: [4]spec.InboundMessage = undefined;
    var cancel: std.atomic.Value(bool) = .init(false);
    const n = try ch.receive(&buf, &cancel);
    defer {
        var i: usize = 0;
        while (i < n) : (i += 1) tg.freeInbound(buf[i]);
    }

    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 10), buf[0].upstream_id);
    try testing.expectEqualStrings("-100", buf[0].conversation_key);
    try testing.expectEqualStrings("77", buf[0].sender_id);
    try testing.expectEqualStrings("hello", buf[0].text);
    try testing.expect(buf[0].thread_key == null);

    try testing.expectEqual(@as(u64, 12), buf[1].upstream_id);
    try testing.expectEqualStrings("5", buf[1].conversation_key);
    try testing.expectEqualStrings("99", buf[1].thread_key.?);
    try testing.expectEqualStrings("world", buf[1].text);

    try testing.expectEqual(@as(?i64, 12), tg.next_offset);
}

const CancelRunner = struct {
    ch: spec.Channel,
    buf: []spec.InboundMessage,
    cancel: *std.atomic.Value(bool),
    result: spec.ReceiveError!usize = 0,

    fn run(self: *CancelRunner) void {
        self.result = self.ch.receive(self.buf, self.cancel);
    }
};

test "telegram channel: receive returns 0 on cancel" {
    // No fake server — a closed socket would have receive error out.
    // We set cancel before the first loop iteration so getUpdates is
    // never called; the receiver returns 0 before touching the network.
    var bot = makeBot("http://127.0.0.1:1");
    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();

    var cancel: std.atomic.Value(bool) = .init(true);
    var buf: [2]spec.InboundMessage = undefined;
    const n = try ch.receive(&buf, &cancel);
    try testing.expectEqual(@as(usize, 0), n);
}

test "telegram channel: receive skips updates without text" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    // Only non-text update in the batch — the receiver advances the
    // offset and loops; we need a second response for the follow-up
    // poll. To keep the test tractable we point the bot at a server
    // that returns the non-text batch, then cancel immediately after —
    // receive should walk the batch, bump next_offset, observe cancel,
    // and return 0.
    var accepted: std.atomic.Value(bool) = .init(false);
    const thread = try spawnFakeServer(
        &server,
        .ok,
        \\{"ok":true,"result":[
        \\  {"update_id":50,"edited_message":{"message_id":1,"chat":{"id":1,"type":"private"}}}
        \\]}
    ,
        &accepted,
    );
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});
    var bot = makeBot(base);

    var tg = TelegramChannel.init(testing.allocator, &bot);
    const ch = tg.channel();

    // Install a watcher thread that flips cancel once the fake server
    // has accepted a connection, so the receive loop exits after
    // processing the single non-text batch.
    var cancel: std.atomic.Value(bool) = .init(false);
    const canceller = try std.Thread.spawn(.{}, struct {
        fn go(accepted_: *std.atomic.Value(bool), cancel_: *std.atomic.Value(bool)) void {
            while (!accepted_.load(.acquire)) {
                std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};
            }
            // Let the response write settle before the receiver finishes
            // parsing the batch and re-enters the loop.
            std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(20_000_000), .awake) catch {};
            cancel_.store(true, .release);
        }
    }.go, .{ &accepted, &cancel });
    defer canceller.join();

    var buf: [2]spec.InboundMessage = undefined;
    const n = try ch.receive(&buf, &cancel);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(?i64, 50), tg.next_offset);
}
