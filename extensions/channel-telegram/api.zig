//! Telegram Bot API client.
//!
//! Wraps the three methods the dispatch worker needs: `getUpdates` for
//! long-polling inbound traffic, `sendMessage` for replies, and
//! `setMyCommands` for the static command list surfaced in the Telegram
//! client's `/` menu. Everything else the upstream API offers — files,
//! inline queries, callback buttons — is deliberately out of scope for
//! v0.1.0.
//!
//! ## Rate limiting
//!
//! Telegram enforces a soft per-chat cap (~1 msg/sec in private chats,
//! 1 msg/minute in groups — we use the stricter private-chat value as a
//! safe baseline) plus a global cap of 30 msg/sec per bot. `sendMessage`
//! blocks on a token bucket mirroring both, so callers can fan out
//! replies across chats without tracking their own pacing.
//!
//! The limiter is keyed by `chat_id`. Per-chat buckets are stored in a
//! small fixed-capacity LRU (32 slots) — more than enough for any realistic
//! bot and small enough that a linear scan costs nothing.
//!
//! ## Threading
//!
//! `getUpdates` is expected to be driven by a single polling thread, but
//! `sendMessage` may be called concurrently by worker threads fanning out
//! replies. The rate-limiter state is guarded by one mutex; `std.http.Client`
//! is thread-safe.

const std = @import("std");

pub const Command = struct {
    command: []const u8,
    description: []const u8,
};

pub const Chat = struct {
    id: i64,
    type: []const u8,
};

pub const User = struct {
    id: i64,
    username: ?[]const u8 = null,
};

pub const Message = struct {
    message_id: i64,
    chat: Chat,
    /// Forum-topic id. Telegram only sets this inside topic-enabled
    /// supergroups; everywhere else it stays null.
    message_thread_id: ?i64 = null,
    from: ?User = null,
    text: ?[]const u8 = null,
};

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
};

/// Bundle returned from `getUpdates`. The backing arena owns every slice
/// referenced by `items`; releasing the arena (`deinit`) frees them all
/// in one shot. Using an arena here avoids per-field tracking when the
/// poller discards an entire batch after dispatch.
pub const Updates = struct {
    items: []Update,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Updates) void {
        self.arena.deinit();
    }
};

pub const SendError = error{
    BadRequest,
    Unauthorized,
    RateLimited,
    TransportFailure,
    OutOfMemory,
};

pub const Bot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Telegram bot token from @BotFather. Caller-owned slice.
    token: []const u8,
    /// Override only for tests pointing at a fake. Defaults to the
    /// public Telegram endpoint.
    base_url: []const u8 = "https://api.telegram.org",
    /// Optional clock for deterministic rate-limit tests. When null,
    /// `std.time.milliTimestamp` is used.
    now_ms: ?*const fn () i64 = null,

    rate_limiter: RateLimiter = .{},

    pub const RateLimiter = struct {
        /// Per-chat: 1 message/sec, burst 1.
        pub const per_chat_hz: f64 = 1.0;
        pub const per_chat_burst: f64 = 1.0;
        /// Global: 30 msg/sec, burst 30.
        pub const global_hz: f64 = 30.0;
        pub const global_burst: f64 = 30.0;

        const lru_capacity: usize = 32;

        const ChatBucket = struct {
            chat_id: i64,
            tokens: f64,
            last_refill_ms: i64,
            touched_ms: i64,
        };

        /// Atomic spinlock. Zig 0.16 dropped std.Thread.Mutex and
        /// std.Io.Mutex requires an Io parameter on lock/unlock, which
        /// would force the Bot-level Io down into the limiter for no
        /// real benefit — the critical section is a few arithmetic
        /// ops over a fixed-size buffer, shorter than a single syscall.
        lock_state: std.atomic.Value(u8) = .init(0),

        global_tokens: f64 = global_burst,
        global_last_refill_ms: i64 = 0,
        global_initialised: bool = false,

        chats: [lru_capacity]ChatBucket = undefined,
        chats_len: usize = 0,

        fn acquire(self: *RateLimiter) void {
            while (self.lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }
        fn release(self: *RateLimiter) void {
            self.lock_state.store(0, .release);
        }

        /// Returns 0 if a token was taken from both buckets, or the
        /// number of milliseconds the caller must sleep before retrying.
        /// Only decrements on success — callers can safely poll this in
        /// a sleep/retry loop.
        pub fn tryAcquire(self: *RateLimiter, chat_id: i64, now: i64) i64 {
            self.acquire();
            defer self.release();

            if (!self.global_initialised) {
                self.global_last_refill_ms = now;
                self.global_initialised = true;
            } else {
                refill(&self.global_tokens, &self.global_last_refill_ms, now, global_hz, global_burst);
            }

            const bucket = self.lookupOrInsert(chat_id, now);
            refill(&bucket.tokens, &bucket.last_refill_ms, now, per_chat_hz, per_chat_burst);
            bucket.touched_ms = now;

            if (self.global_tokens >= 1.0 and bucket.tokens >= 1.0) {
                self.global_tokens -= 1.0;
                bucket.tokens -= 1.0;
                return 0;
            }

            const global_wait = waitMs(self.global_tokens, global_hz);
            const chat_wait = waitMs(bucket.tokens, per_chat_hz);
            const wait = @max(global_wait, chat_wait);
            return if (wait <= 0) 1 else wait;
        }

        fn lookupOrInsert(self: *RateLimiter, chat_id: i64, now: i64) *ChatBucket {
            for (self.chats[0..self.chats_len]) |*b| {
                if (b.chat_id == chat_id) return b;
            }
            if (self.chats_len < lru_capacity) {
                const slot = &self.chats[self.chats_len];
                self.chats_len += 1;
                slot.* = .{
                    .chat_id = chat_id,
                    .tokens = per_chat_burst,
                    .last_refill_ms = now,
                    .touched_ms = now,
                };
                return slot;
            }
            // Evict least-recently-touched.
            var victim: *ChatBucket = &self.chats[0];
            for (self.chats[1..]) |*b| {
                if (b.touched_ms < victim.touched_ms) victim = b;
            }
            victim.* = .{
                .chat_id = chat_id,
                .tokens = per_chat_burst,
                .last_refill_ms = now,
                .touched_ms = now,
            };
            return victim;
        }

        fn refill(tokens: *f64, last_ms: *i64, now: i64, hz: f64, burst: f64) void {
            if (now <= last_ms.*) return;
            const dt_ms: f64 = @floatFromInt(now - last_ms.*);
            tokens.* = @min(burst, tokens.* + dt_ms / 1000.0 * hz);
            last_ms.* = now;
        }

        fn waitMs(tokens: f64, hz: f64) i64 {
            if (tokens >= 1.0) return 0;
            const ms: f64 = (1.0 - tokens) / hz * 1000.0;
            return @as(i64, @intFromFloat(@ceil(ms)));
        }
    };

    pub fn deinit(self: *Bot) void {
        _ = self;
    }

    pub fn getUpdates(
        self: *Bot,
        offset: ?i64,
        timeout_seconds: u32,
        allocator: std.mem.Allocator,
    ) !?Updates {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aalloc = arena.allocator();

        var body_buf: std.array_list.Aligned(u8, null) = .empty;
        defer body_buf.deinit(self.allocator);

        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &body_buf);
        var stringify: std.json.Stringify = .{ .writer = &aw.writer };
        try stringify.beginObject();
        try stringify.objectField("timeout");
        try stringify.write(timeout_seconds);
        if (offset) |o| {
            try stringify.objectField("offset");
            try stringify.write(o);
        }
        try stringify.endObject();

        const body = try aw.toOwnedSlice();
        defer self.allocator.free(body);

        const resp = self.postMethod("getUpdates", body, aalloc) catch
            return error.TransportFailure;
        defer self.allocator.free(resp.body);

        if (resp.status != 200) return error.TransportFailure;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, aalloc, resp.body, .{}) catch
            return error.TransportFailure;
        if (parsed != .object) return error.TransportFailure;
        const result = parsed.object.get("result") orelse return null;
        if (result != .array) return error.TransportFailure;
        if (result.array.items.len == 0) return null;

        var out = try aalloc.alloc(Update, result.array.items.len);
        for (result.array.items, 0..) |entry, idx| {
            out[idx] = try parseUpdate(aalloc, entry);
        }

        return .{ .items = out, .arena = arena };
    }

    pub fn sendMessage(
        self: *Bot,
        chat_id: i64,
        text: []const u8,
        reply_to_message_id: ?i64,
    ) SendError!i64 {
        while (true) {
            const wait_ms = self.rate_limiter.tryAcquire(chat_id, self.nowMs());
            if (wait_ms == 0) break;
            const ns: u64 = @as(u64, @intCast(wait_ms)) * std.time.ns_per_ms;
            std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(ns), .awake) catch {};
        }

        const body = buildSendMessageBody(self.allocator, chat_id, text, reply_to_message_id) catch
            return error.OutOfMemory;
        defer self.allocator.free(body);

        const resp = self.postMethod("sendMessage", body, self.allocator) catch
            return error.TransportFailure;
        defer self.allocator.free(resp.body);

        switch (resp.status) {
            200 => {},
            400 => return error.BadRequest,
            401, 403 => return error.Unauthorized,
            429 => return error.RateLimited,
            else => return error.TransportFailure,
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch
            return error.TransportFailure;
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.TransportFailure;
        if (result != .object) return error.TransportFailure;
        const mid = result.object.get("message_id") orelse return error.TransportFailure;
        if (mid != .integer) return error.TransportFailure;
        return mid.integer;
    }

    /// Minimal bot identity returned by `getMe`. Only the fields
    /// startup actually uses — v1 carried a larger struct covering
    /// first_name, can_join_groups, etc., which we don't need yet.
    pub const Identity = struct {
        id: i64,
        /// Bot username without the leading `@`. Caller owns the slice.
        username: []u8,

        pub fn deinit(self: Identity, allocator: std.mem.Allocator) void {
            allocator.free(self.username);
        }
    };

    /// Confirm the token is valid and return the bot's username.
    /// Startup uses this as a handshake — if it fails the daemon
    /// refuses to register the channel rather than silently polling a
    /// bad endpoint.
    pub fn getMe(self: *Bot) !Identity {
        const resp = self.postMethod("getMe", "{}", self.allocator) catch
            return error.TransportFailure;
        defer self.allocator.free(resp.body);

        switch (resp.status) {
            200 => {},
            401, 403 => return error.Unauthorized,
            else => return error.TransportFailure,
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch
            return error.TransportFailure;
        defer parsed.deinit();

        const ok = parsed.value.object.get("ok") orelse return error.TransportFailure;
        if (ok != .bool or !ok.bool) return error.Unauthorized;

        const result = parsed.value.object.get("result") orelse return error.TransportFailure;
        if (result != .object) return error.TransportFailure;

        const id_v = result.object.get("id") orelse return error.TransportFailure;
        if (id_v != .integer) return error.TransportFailure;

        const uname_v = result.object.get("username") orelse return error.TransportFailure;
        if (uname_v != .string) return error.TransportFailure;

        const uname_dup = self.allocator.dupe(u8, uname_v.string) catch
            return error.OutOfMemory;
        return .{ .id = id_v.integer, .username = uname_dup };
    }

    /// Clear any webhook Telegram currently holds for this bot without
    /// dropping unacked updates. Telegram refuses `getUpdates` while a
    /// webhook is active, so startup calls this unconditionally — it's
    /// a no-op if no webhook is set.
    pub fn deleteWebhookKeepPending(self: *Bot) !void {
        const resp = self.postMethod(
            "deleteWebhook",
            "{\"drop_pending_updates\":false}",
            self.allocator,
        ) catch return error.TransportFailure;
        defer self.allocator.free(resp.body);
        switch (resp.status) {
            200 => {},
            401, 403 => return error.Unauthorized,
            else => return error.TransportFailure,
        }
    }

    pub fn setMyCommands(self: *Bot, commands: []const Command) !void {
        var body_buf: std.array_list.Aligned(u8, null) = .empty;
        defer body_buf.deinit(self.allocator);

        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &body_buf);
        var stringify: std.json.Stringify = .{ .writer = &aw.writer };
        try stringify.beginObject();
        try stringify.objectField("commands");
        try stringify.beginArray();
        for (commands) |c| {
            try stringify.beginObject();
            try stringify.objectField("command");
            try stringify.write(c.command);
            try stringify.objectField("description");
            try stringify.write(c.description);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();

        const body = try aw.toOwnedSlice();
        defer self.allocator.free(body);

        const resp = self.postMethod("setMyCommands", body, self.allocator) catch
            return error.TransportFailure;
        defer self.allocator.free(resp.body);
        if (resp.status != 200) return error.TransportFailure;
    }

    fn nowMs(self: *Bot) i64 {
        if (self.now_ms) |f| return f();
        // std.time.milliTimestamp was dropped in Zig 0.16; go through
        // libc clock_gettime and collapse to ms. link_libc is required
        // on the extension module for this to resolve.
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
        const sec_ms: i64 = @divFloor(@as(i64, ts.sec) * std.time.ns_per_s, std.time.ns_per_ms);
        const nsec_ms: i64 = @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        return sec_ms + nsec_ms;
    }

    const HttpResponse = struct {
        status: u16,
        body: []u8,
    };

    /// POSTs `body` as JSON to `<base_url>/bot<token>/<method>` and
    /// returns the response status + body (caller owns `body`, allocated
    /// from `self.allocator`).
    ///
    /// Shells out to `curl` because std.http.Client on darwin with
    /// Zig 0.16 busy-loops on long-lived TLS reads instead of
    /// progressing. The subprocess is predictable on every platform
    /// we target — cost is one fork per Bot API call, dominated by
    /// Telegram round-trip time anyway.
    fn postMethod(
        self: *Bot,
        method: []const u8,
        body: []const u8,
        _: std.mem.Allocator,
    ) !HttpResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/bot{s}/{s}",
            .{ self.base_url, self.token, method },
        );
        defer self.allocator.free(url);

        // 60s --max-time: Telegram getUpdates uses a 30s server-side
        // long-poll. 60s gives us a 2x safety margin for the full
        // request including connect + TLS handshake.
        const argv = [_][]const u8{
            "curl",
            "-s",
            "--max-time",
            "60",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
            "-w",
            "\n%{http_code}",
            url,
        };

        var child = try std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        if (child.stdin) |stdin_file| {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_writer = stdin_file.writer(self.io, &stdin_buf);
            stdin_writer.interface.writeAll(body) catch {
                stdin_file.close(self.io);
                child.stdin = null;
                child.kill(self.io);
                _ = child.wait(self.io) catch {};
                return error.TransportFailure;
            };
            stdin_writer.interface.flush() catch {};
            stdin_file.close(self.io);
            child.stdin = null;
        }

        var stdout_buf: [8192]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(self.io, &stdout_buf);

        var collected: std.Io.Writer.Allocating = .init(self.allocator);
        defer collected.deinit();
        _ = stdout_reader.interface.streamRemaining(&collected.writer) catch {};
        const stdout = collected.toOwnedSlice() catch return error.TransportFailure;
        errdefer self.allocator.free(stdout);

        const term = child.wait(self.io) catch return error.TransportFailure;
        switch (term) {
            .exited => |code| if (code != 0) return error.TransportFailure,
            else => return error.TransportFailure,
        }

        // `-w "\n%{http_code}"` appends a newline-separated status at
        // the end of stdout. Split it off; the part before the last
        // newline is the real response body.
        const sep = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse return error.TransportFailure;
        const status_raw = std.mem.trim(u8, stdout[sep + 1 ..], " \t\r\n");
        if (status_raw.len != 3) return error.TransportFailure;
        const status_code = std.fmt.parseInt(u16, status_raw, 10) catch return error.TransportFailure;

        const body_slice = stdout[0..sep];
        const response_body = try self.allocator.dupe(u8, body_slice);
        self.allocator.free(stdout);

        return .{ .status = status_code, .body = response_body };
    }
};

/// Pure helper exposed so the wire shape can be pinned in tests without
/// standing up an HTTP client. Emits the canonical sendMessage body; we
/// deliberately omit `parse_mode` — plain text is the safe default.
pub fn buildSendMessageBody(
    allocator: std.mem.Allocator,
    chat_id: i64,
    text: []const u8,
    reply_to_message_id: ?i64,
) ![]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    defer buf.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.beginObject();
    try stringify.objectField("chat_id");
    try stringify.write(chat_id);
    try stringify.objectField("text");
    try stringify.write(text);
    if (reply_to_message_id) |r| {
        try stringify.objectField("reply_to_message_id");
        try stringify.write(r);
    }
    try stringify.endObject();
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Update parsing

fn parseUpdate(arena: std.mem.Allocator, v: std.json.Value) !Update {
    if (v != .object) return error.BadUpdate;
    const update_id = v.object.get("update_id") orelse return error.BadUpdate;
    if (update_id != .integer) return error.BadUpdate;

    var upd: Update = .{ .update_id = update_id.integer };
    if (v.object.get("message")) |m| {
        upd.message = try parseMessage(arena, m);
    }
    return upd;
}

fn parseMessage(arena: std.mem.Allocator, v: std.json.Value) !Message {
    if (v != .object) return error.BadUpdate;
    const mid = v.object.get("message_id") orelse return error.BadUpdate;
    if (mid != .integer) return error.BadUpdate;
    const chat_v = v.object.get("chat") orelse return error.BadUpdate;

    var msg: Message = .{
        .message_id = mid.integer,
        .chat = try parseChat(arena, chat_v),
    };
    if (v.object.get("message_thread_id")) |t| {
        if (t == .integer) msg.message_thread_id = t.integer;
    }
    if (v.object.get("from")) |f| {
        msg.from = try parseUser(arena, f);
    }
    if (v.object.get("text")) |t| {
        if (t == .string) msg.text = try arena.dupe(u8, t.string);
    }
    return msg;
}

fn parseChat(arena: std.mem.Allocator, v: std.json.Value) !Chat {
    if (v != .object) return error.BadUpdate;
    const id = v.object.get("id") orelse return error.BadUpdate;
    if (id != .integer) return error.BadUpdate;
    const kind = v.object.get("type") orelse return error.BadUpdate;
    if (kind != .string) return error.BadUpdate;
    return .{
        .id = id.integer,
        .type = try arena.dupe(u8, kind.string),
    };
}

fn parseUser(arena: std.mem.Allocator, v: std.json.Value) !User {
    if (v != .object) return error.BadUpdate;
    const id = v.object.get("id") orelse return error.BadUpdate;
    if (id != .integer) return error.BadUpdate;
    var u: User = .{ .id = id.integer };
    if (v.object.get("username")) |n| {
        if (n == .string) u.username = try arena.dupe(u8, n.string);
    }
    return u;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "telegram: buildSendMessageBody without reply" {
    const body = try buildSendMessageBody(testing.allocator, 42, "hi there", null);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"chat_id\":42") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"text\":\"hi there\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "reply_to_message_id") == null);
    try testing.expect(std.mem.indexOf(u8, body, "parse_mode") == null);
}

test "telegram: buildSendMessageBody with reply id" {
    const body = try buildSendMessageBody(testing.allocator, -100500, "yo", 99);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"chat_id\":-100500") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reply_to_message_id\":99") != null);
}

test "telegram: rate limiter per-chat cap forces caller to wait ~1s" {
    var rl: Bot.RateLimiter = .{};
    // First call at t=0 consumes the burst token.
    try testing.expectEqual(@as(i64, 0), rl.tryAcquire(7, 0));
    // Second call in the same chat immediately after must wait roughly 1s.
    const wait = rl.tryAcquire(7, 10);
    try testing.expect(wait >= 900 and wait <= 1100);
    // A fully-refilled window lets us through again.
    try testing.expectEqual(@as(i64, 0), rl.tryAcquire(7, 2000));
}

test "telegram: rate limiter global cap engages after 30 sends" {
    var rl: Bot.RateLimiter = .{};
    // 30 distinct chats consume the global burst in under a second.
    var i: i64 = 0;
    while (i < 30) : (i += 1) {
        try testing.expectEqual(@as(i64, 0), rl.tryAcquire(i + 1, i));
    }
    // 31st send on a fresh chat must now wait on the global bucket.
    const wait = rl.tryAcquire(999, 30);
    try testing.expect(wait > 0);
}

test "telegram: rate limiter LRU evicts oldest chat" {
    var rl: Bot.RateLimiter = .{};
    var i: i64 = 0;
    while (i < 32) : (i += 1) {
        _ = rl.tryAcquire(i, i);
    }
    try testing.expectEqual(@as(usize, 32), rl.chats_len);
    // Insert a 33rd chat — the capacity stays at 32 and chat_id=0 is gone.
    _ = rl.tryAcquire(1000, 10_000);
    try testing.expectEqual(@as(usize, 32), rl.chats_len);
    var found_zero = false;
    var found_new = false;
    for (rl.chats[0..rl.chats_len]) |b| {
        if (b.chat_id == 0) found_zero = true;
        if (b.chat_id == 1000) found_new = true;
    }
    try testing.expect(!found_zero);
    try testing.expect(found_new);
}

test "telegram: parseUpdate round-trips a realistic payload" {
    const json =
        \\{"update_id":123,"message":{"message_id":7,"message_thread_id":44,
        \\ "from":{"id":11,"username":"omkar"},
        \\ "chat":{"id":-100500,"type":"supergroup"},
        \\ "text":"hello world"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const upd = try parseUpdate(a, parsed);
    try testing.expectEqual(@as(i64, 123), upd.update_id);
    try testing.expect(upd.message != null);
    const msg = upd.message.?;
    try testing.expectEqual(@as(i64, 7), msg.message_id);
    try testing.expectEqual(@as(?i64, 44), msg.message_thread_id);
    try testing.expectEqualStrings("hello world", msg.text.?);
    try testing.expectEqual(@as(i64, -100500), msg.chat.id);
    try testing.expectEqualStrings("supergroup", msg.chat.type);
    try testing.expect(msg.from != null);
    try testing.expectEqualStrings("omkar", msg.from.?.username.?);
}

// --- fake server plumbing --------------------------------------------------

const FakeServerArgs = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
};

fn fakeServerThread(args: *FakeServerArgs) void {
    var stream = args.server.accept(args.io) catch return;
    defer stream.close(args.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var s_reader = stream.reader(args.io, &read_buf);
    var s_writer = stream.writer(args.io, &write_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond(args.body, .{
        .status = args.status,
        .keep_alive = false,
    }) catch return;
}

test "telegram: sendMessage maps 401 to Unauthorized" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .unauthorized,
        .body = "{\"ok\":false,\"description\":\"bad token\"}",
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var bot: Bot = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .token = "test",
        .base_url = base,
    };
    defer bot.deinit();

    try testing.expectError(SendError.Unauthorized, bot.sendMessage(42, "hi", null));
}

test "telegram: sendMessage parses message_id on success" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .ok,
        .body =
        \\{"ok":true,"result":{"message_id":555,"chat":{"id":42,"type":"private"},"text":"hi"}}
        ,
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var bot: Bot = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .token = "test",
        .base_url = base,
    };
    defer bot.deinit();

    const mid = try bot.sendMessage(42, "hi", null);
    try testing.expectEqual(@as(i64, 555), mid);
}
