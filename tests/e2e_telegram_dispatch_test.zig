//! End-to-end test for the inbound → dispatch → outbound pipeline
//! against a fake Telegram HTTP backend.
//!
//! A simulated Telegram update enters through a Channel adapter that
//! speaks the same wire shape as the real Telegram extension (long-poll
//! `getUpdates`, JSON `sendMessage` payloads). It rides the
//! `Manager → Dispatch` FIFO, is consumed by a caller-owned dispatch
//! worker that drives a `MockAgentRunner`, and finally comes out as a
//! `sendMessage` HTTP POST back to the fake server. The test asserts
//! that the outgoing body carries the expected echoed text, pinning
//! the full round-trip as a single observable behaviour.
//!
//! The adapter here is local to the test on purpose: the point of the
//! test is the pipeline contract (Channel → Manager → Dispatch →
//! worker → Channel.send), not Telegram API specifics, and keeping
//! the adapter in-tree avoids coupling the integration test to the
//! extension module's evolving surface.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const spec = tigerclaw.channels.spec;
const dispatch_mod = tigerclaw.channels.dispatch;
const manager_mod = tigerclaw.channels.manager;
const harness = tigerclaw.harness;

/// Max accepts before the fake server thread gives up. The happy path
/// uses only a handful (initial getUpdates, one empty poll, one
/// sendMessage); the ceiling exists so a buggy run cannot spin
/// forever.
const max_accepts: u32 = 32;

/// Fixed-size capture slot for the sendMessage body observed by the
/// fake server. A single-shot buffer + `published` flag keeps the
/// cross-thread handoff free of any mutex type — Zig 0.16 dropped the
/// `std.Thread.Mutex` alias and `std.Io.Mutex` demands an `Io` handle
/// we do not want to thread through a capture fixture.
const capture_buf_size: usize = 512;

const FakeServer = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    stop: std.atomic.Value(bool) = .init(false),
    update_served: std.atomic.Value(bool) = .init(false),

    captured_text_buf: [capture_buf_size]u8 = undefined,
    captured_text_len: usize = 0,
    captured_chat_id: i64 = 0,
    /// Flipped with `.release` after the buffer is filled; readers
    /// `.acquire` then read. Single-writer / many-reader — no lock.
    published: std.atomic.Value(bool) = .init(false),

    fn capture(self: *FakeServer, text: []const u8, chat_id: i64) void {
        if (self.published.load(.acquire)) return; // single-shot
        const n = @min(text.len, self.captured_text_buf.len);
        @memcpy(self.captured_text_buf[0..n], text[0..n]);
        self.captured_text_len = n;
        self.captured_chat_id = chat_id;
        self.published.store(true, .release);
    }

    fn snapshot(self: *FakeServer) ?[]const u8 {
        if (!self.published.load(.acquire)) return null;
        return self.captured_text_buf[0..self.captured_text_len];
    }
};

const update_payload =
    \\{"ok":true,"result":[
    \\  {"update_id":501,"message":{"message_id":1,"from":{"id":77,"username":"tester"},"chat":{"id":42,"type":"private"},"text":"hello tigerclaw"}}
    \\]}
;

const empty_payload = "{\"ok\":true,\"result\":[]}";

const send_ok_payload =
    \\{"ok":true,"result":{"message_id":99,"chat":{"id":42,"type":"private"},"text":"echoed"}}
;

fn fakeServerLoop(fs: *FakeServer) void {
    var accepts: u32 = 0;
    while (!fs.stop.load(.acquire) and accepts < max_accepts) : (accepts += 1) {
        var stream = fs.listener.accept(fs.io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return,
        };
        defer stream.close(fs.io);
        handleOne(fs, &stream) catch {};
    }
}

fn handleOne(fs: *FakeServer, stream: *std.Io.net.Stream) !void {
    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;

    var s_reader = stream.reader(fs.io, &read_buf);
    var s_writer = stream.writer(fs.io, &write_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;

    const target = request.head.target;

    if (std.mem.endsWith(u8, target, "/getUpdates")) {
        var body_scratch: [1024]u8 = undefined;
        _ = request.readerExpectNone(&body_scratch).readSliceShort(&body_scratch) catch {};

        const first = !fs.update_served.swap(true, .acq_rel);
        const body: []const u8 = if (first) update_payload else empty_payload;
        request.respond(body, .{ .status = .ok, .keep_alive = false }) catch {};
        return;
    }

    if (std.mem.endsWith(u8, target, "/sendMessage")) {
        var body_buf: [4 * 1024]u8 = undefined;
        const n = request.readerExpectNone(&body_buf).readSliceShort(&body_buf) catch 0;
        parseAndCapture(fs, body_buf[0..n]) catch {};
        request.respond(send_ok_payload, .{ .status = .ok, .keep_alive = false }) catch {};
        return;
    }

    request.respond("not found\n", .{ .status = .not_found, .keep_alive = false }) catch {};
}

fn parseAndCapture(fs: *FakeServer, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const text_val = parsed.value.object.get("text") orelse return;
    const chat_val = parsed.value.object.get("chat_id") orelse return;
    if (text_val != .string or chat_val != .integer) return;
    fs.capture(text_val.string, chat_val.integer);
}

// --- test-local channel adapter ---------------------------------------------

/// Minimal Telegram-shaped channel that talks real HTTP to the fake
/// server. `receive` pulls once via `getUpdates` and then long-polls
/// with an empty body; `send` POSTs a `{ chat_id, text }` payload to
/// `sendMessage`. This mirrors the wire shape the production Telegram
/// extension emits, without depending on the extension's Bot type.
const TestTelegramChannel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    token: []const u8 = "test-token",
    next_offset: ?i64 = null,

    fn channel(self: *TestTelegramChannel) spec.Channel {
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

    fn deinitFn(_: *anyopaque) void {}

    fn freeInbound(self: *TestTelegramChannel, msg: spec.InboundMessage) void {
        self.allocator.free(msg.conversation_key);
        if (msg.thread_key) |t| self.allocator.free(t);
        self.allocator.free(msg.sender_id);
        self.allocator.free(msg.text);
    }

    fn sendFn(ptr: *anyopaque, msg: spec.OutboundMessage) spec.SendError!void {
        const self: *TestTelegramChannel = @ptrCast(@alignCast(ptr));

        const chat_id = std.fmt.parseInt(i64, msg.conversation_key, 10) catch
            return spec.SendError.BadRequest;

        const body = buildSendBody(self.allocator, chat_id, msg.text) catch
            return spec.SendError.TransportFailure;
        defer self.allocator.free(body);

        const status = self.postMethod("sendMessage", body) catch
            return spec.SendError.TransportFailure;
        switch (status) {
            200 => return,
            400 => return spec.SendError.BadRequest,
            401, 403 => return spec.SendError.Unauthorized,
            429 => return spec.SendError.RateLimited,
            else => return spec.SendError.TransportFailure,
        }
    }

    fn receiveFn(
        ptr: *anyopaque,
        buf: []spec.InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) spec.ReceiveError!usize {
        const self: *TestTelegramChannel = @ptrCast(@alignCast(ptr));
        while (true) {
            if (cancel.load(.acquire)) return 0;

            const n = self.pollOnce(buf) catch |err| switch (err) {
                error.Transport => {
                    // Short pause before retrying, cancellable via Io.
                    std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
                    continue;
                },
            };

            if (cancel.load(.acquire)) {
                var i: usize = 0;
                while (i < n) : (i += 1) self.freeInbound(buf[i]);
                return 0;
            }

            if (n > 0) return n;
            // Empty poll — loop again; the fake's empty response keeps
            // the caller polling until cancel flips.
            std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        }
    }

    fn pollOnce(self: *TestTelegramChannel, buf: []spec.InboundMessage) error{Transport}!usize {
        const req_body = buildGetBody(self.allocator, self.next_offset) catch return error.Transport;
        defer self.allocator.free(req_body);

        var resp_body: []u8 = undefined;
        const status = self.postMethodCapture("getUpdates", req_body, &resp_body) catch return error.Transport;
        defer self.allocator.free(resp_body);
        if (status != 200) return error.Transport;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp_body, .{}) catch
            return error.Transport;
        defer parsed.deinit();

        if (parsed.value != .object) return error.Transport;
        const result = parsed.value.object.get("result") orelse return 0;
        if (result != .array) return error.Transport;

        var written: usize = 0;
        var highest: i64 = self.next_offset orelse std.math.minInt(i64);

        for (result.array.items) |upd| {
            if (upd != .object) continue;
            const uid_val = upd.object.get("update_id") orelse continue;
            if (uid_val != .integer) continue;
            if (uid_val.integer > highest) highest = uid_val.integer;
            if (written >= buf.len) continue;

            const msg_val = upd.object.get("message") orelse continue;
            if (msg_val != .object) continue;
            const text_val = msg_val.object.get("text") orelse continue;
            if (text_val != .string) continue;
            const chat_val = msg_val.object.get("chat") orelse continue;
            if (chat_val != .object) continue;
            const chat_id_val = chat_val.object.get("id") orelse continue;
            if (chat_id_val != .integer) continue;

            const sender_id: i64 = blk: {
                const from_val = msg_val.object.get("from") orelse break :blk 0;
                if (from_val != .object) break :blk 0;
                const from_id_val = from_val.object.get("id") orelse break :blk 0;
                if (from_id_val != .integer) break :blk 0;
                break :blk from_id_val.integer;
            };

            const inbound = self.buildInbound(
                @intCast(@max(uid_val.integer, 0)),
                chat_id_val.integer,
                sender_id,
                text_val.string,
            ) catch return error.Transport;
            buf[written] = inbound;
            written += 1;
        }

        self.next_offset = highest;
        return written;
    }

    fn buildInbound(
        self: *TestTelegramChannel,
        update_id: u64,
        chat_id: i64,
        sender_id: i64,
        text: []const u8,
    ) !spec.InboundMessage {
        var conv_buf: [32]u8 = undefined;
        const conv_slice = std.fmt.bufPrint(&conv_buf, "{d}", .{chat_id}) catch unreachable;
        const conv = try self.allocator.dupe(u8, conv_slice);
        errdefer self.allocator.free(conv);

        var sbuf: [32]u8 = undefined;
        const sender_slice = std.fmt.bufPrint(&sbuf, "{d}", .{sender_id}) catch unreachable;
        const sender = try self.allocator.dupe(u8, sender_slice);
        errdefer self.allocator.free(sender);

        const text_owned = try self.allocator.dupe(u8, text);

        return .{
            .upstream_id = update_id,
            .conversation_key = conv,
            .thread_key = null,
            .sender_id = sender,
            .text = text_owned,
        };
    }

    fn postMethod(self: *TestTelegramChannel, method: []const u8, body: []const u8) !u16 {
        var scratch: []u8 = undefined;
        const status = try self.postMethodCapture(method, body, &scratch);
        self.allocator.free(scratch);
        return status;
    }

    fn postMethodCapture(
        self: *TestTelegramChannel,
        method: []const u8,
        body: []const u8,
        out_body: *[]u8,
    ) !u16 {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/bot{s}/{s}", .{ self.base_url, self.token, method });

        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var headers_buf: [1]std.http.Header = .{
            .{ .name = "content-type", .value = "application/json" },
        };

        var req = try client.request(.POST, uri, .{
            .keep_alive = false,
            .extra_headers = headers_buf[0..],
        });
        defer req.deinit();

        const body_dup = try self.allocator.dupe(u8, body);
        defer self.allocator.free(body_dup);
        try req.sendBodyComplete(body_dup);

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        const code: u16 = @intFromEnum(response.head.status);

        var transfer_buf: [8 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var collected: std.Io.Writer.Allocating = .init(self.allocator);
        defer collected.deinit();
        _ = reader.streamRemaining(&collected.writer) catch {};

        out_body.* = try collected.toOwnedSlice();
        return code;
    }
};

fn buildSendBody(allocator: std.mem.Allocator, chat_id: i64, text: []const u8) ![]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.beginObject();
    try stringify.objectField("chat_id");
    try stringify.write(chat_id);
    try stringify.objectField("text");
    try stringify.write(text);
    try stringify.endObject();
    return try aw.toOwnedSlice();
}

fn buildGetBody(allocator: std.mem.Allocator, offset: ?i64) ![]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.beginObject();
    try stringify.objectField("timeout");
    try stringify.write(1);
    if (offset) |o| {
        try stringify.objectField("offset");
        try stringify.write(o);
    }
    try stringify.endObject();
    return try aw.toOwnedSlice();
}

// --- dispatch worker --------------------------------------------------------

const WorkerArgs = struct {
    dispatch: *dispatch_mod.Dispatch,
    channel: spec.Channel,
    tg: *TestTelegramChannel,
    runner: harness.AgentRunner,
    cancel: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
};

fn dispatchWorker(args: *WorkerArgs) void {
    while (true) {
        const msg = args.dispatch.dequeue(args.cancel) orelse return;

        args.dispatch.beginTurn();
        defer args.dispatch.endTurn();

        const result = args.runner.run(.{
            .session_id = msg.conversation_key,
            .input = msg.text,
        }) catch {
            args.tg.freeInbound(msg);
            continue;
        };

        const reply = std.fmt.allocPrint(args.allocator, "echo: {s}", .{result.output}) catch {
            args.tg.freeInbound(msg);
            continue;
        };
        defer args.allocator.free(reply);

        args.channel.send(.{
            .conversation_key = msg.conversation_key,
            .text = reply,
        }) catch {};

        args.tg.freeInbound(msg);
    }
}

// --- the test ---------------------------------------------------------------

test "telegram-shaped channel: inbound update drives a sendMessage back through the pipeline" {
    // Bind the fake listener on the test thread so the worker thread
    // receives a live `*std.Io.net.Server` with no probe-then-rebind
    // race.
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var listener = try addr.listen(testing.io, .{ .reuse_address = true });
    defer listener.deinit(testing.io);
    const port = listener.socket.address.getPort();

    var fs: FakeServer = .{ .io = testing.io, .listener = &listener };
    const server_thread = try std.Thread.spawn(.{}, fakeServerLoop, .{&fs});
    defer {
        fs.stop.store(true, .release);
        const wake_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        if (wake_addr.connect(testing.io, .{ .mode = .stream, .protocol = .tcp })) |s| {
            var w = s;
            w.close(testing.io);
        } else |_| {}
        server_thread.join();
    }

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var tg: TestTelegramChannel = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .base_url = base,
    };

    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 16);
    defer dispatch.deinit();

    var mgr = manager_mod.Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();
    mgr.retry_backoff_ns = 1 * std.time.ns_per_ms;

    try mgr.add("default", tg.channel());

    var mock = harness.MockAgentRunner.init();
    // Mock echoes input verbatim; the dispatch worker stamps the
    // "echo: " prefix so the assertion anchors on a marker that can't
    // already be present in the inbound text.
    mock.reply_prefix = "";

    var worker_cancel: std.atomic.Value(bool) = .init(false);
    var worker_args: WorkerArgs = .{
        .dispatch = &dispatch,
        .channel = tg.channel(),
        .tg = &tg,
        .runner = mock.runner(),
        .cancel = &worker_cancel,
        .allocator = testing.allocator,
    };
    const worker_thread = try std.Thread.spawn(.{}, dispatchWorker, .{&worker_args});
    defer {
        worker_cancel.store(true, .release);
        worker_thread.join();
    }

    try mgr.start();
    defer mgr.stop();

    const deadline_ns: u64 = 5 * std.time.ns_per_s;
    const poll_ns: u64 = 10 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < deadline_ns) {
        if (fs.snapshot()) |_| break;
        std.Io.sleep(testing.io, std.Io.Duration.fromNanoseconds(poll_ns), .awake) catch {};
        waited_ns +|= poll_ns;
    }

    const captured = fs.snapshot();
    try testing.expect(captured != null);
    try testing.expectEqualStrings("echo: hello tigerclaw", captured.?);
    try testing.expectEqual(@as(i64, 42), fs.captured_chat_id);

    const s = dispatch.stats();
    try testing.expect(s.enqueued >= 1);
    try testing.expect(s.drained >= 1);
}
