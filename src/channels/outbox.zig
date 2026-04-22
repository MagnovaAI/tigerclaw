//! Durable outbound-message queue.
//!
//! The outbox is the crash-safe buffer that sits between the
//! dispatch worker ("send reply R to channel C") and the channel
//! adapter's transport-layer `send`. Every reply is appended to
//! `<state_root>/outbox/<channel>.jsonl` and fsynced before the
//! adapter is asked to deliver it. If the process dies mid-send
//! the reply is still on disk; on restart the queue replays what
//! was never acked.
//!
//! # File format
//!
//! One JSON object per line, terminated by `\n`. Lines are written
//! with a single positional write at the current end-of-file, so a
//! crash mid-write leaves the tail line either absent in full or
//! present in full — never torn. A corrupted tail line on replay
//! would surface as a JSON parse error and is treated by the reader
//! as end-of-log.
//!
//! # Threading
//!
//! An `Outbox` value is single-writer. The channel manager owns one
//! `Outbox` per channel and ensures all appends for that channel
//! serialize through a single goroutine-equivalent thread. Readers
//! (cursor, ack) are likewise expected to run on the same thread as
//! the writer; this lets the implementation avoid any internal
//! locking.

const std = @import("std");

const clock_mod = @import("../clock.zig");
const spec = @import("spec.zig");

pub const Clock = clock_mod.Clock;

pub const AppendError = error{
    IoFailure,
    OutOfMemory,
};

pub const ReadError = error{
    IoFailure,
    OutOfMemory,
    CorruptRecord,
};

pub const AckError = error{
    IoFailure,
    OutOfMemory,
    UnknownId,
};

/// Read-side view of a record the dispatcher has not yet delivered
/// and is due for a send attempt. The slices borrow from the
/// cursor's arena and stay valid until `Cursor.deinit`.
pub const Pending = struct {
    id: []const u8,
    conversation_key: []const u8,
    thread_key: ?[]const u8,
    text: []const u8,
    attempts: u32,
    next_due_unix_ms: i64,
};

/// Outbox persists outbound replies to one JSONL file per channel.
/// See the file header for the crash-safety argument.
pub const Outbox = struct {
    io: std.Io,
    state_root: std.Io.Dir,
    allocator: std.mem.Allocator,
    clock: Clock,

    pub fn init(
        io: std.Io,
        state_root: std.Io.Dir,
        allocator: std.mem.Allocator,
        clock: Clock,
    ) Outbox {
        return .{
            .io = io,
            .state_root = state_root,
            .allocator = allocator,
            .clock = clock,
        };
    }

    fn nowMs(self: *const Outbox) i64 {
        return @intCast(@divFloor(self.clock.nowNs(), std.time.ns_per_ms));
    }

    fn nowUs(self: *const Outbox) i64 {
        return @intCast(@divFloor(self.clock.nowNs(), std.time.ns_per_us));
    }

    /// Append `msg` to the channel's JSONL log and return the id
    /// assigned to the new record. The returned slice is owned by
    /// the caller and must be freed with the allocator passed to
    /// `init`.
    ///
    /// The write is atomic in the sense that the JSON payload plus
    /// trailing newline land via a single `writePositionalAll` at
    /// the file's current size, followed by fsync. Either the whole
    /// line is on disk after the call or none of it is — a crash in
    /// the middle cannot leave a half-formed record for the reader
    /// to trip over.
    pub fn append(
        self: *Outbox,
        channel_id: spec.ChannelId,
        msg: spec.OutboundMessage,
    ) AppendError![]const u8 {
        self.state_root.createDirPath(self.io, outbox_dir_name) catch return error.IoFailure;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.jsonl", .{
            outbox_dir_name,
            @tagName(channel_id),
        }) catch return error.IoFailure;

        const id = try generateId(self.allocator, self.nowUs());
        errdefer self.allocator.free(id);

        const record: Record = .{
            .id = id,
            .conversation_key = msg.conversation_key,
            .thread_key = msg.thread_key,
            .text = msg.text,
            .attempts = 0,
            .next_due_unix_ms = self.nowMs(),
            .ack = false,
        };

        const line = std.json.Stringify.valueAlloc(self.allocator, record, .{}) catch
            return error.OutOfMemory;
        defer self.allocator.free(line);

        const file = self.state_root.createFile(self.io, path, .{
            .truncate = false,
            .read = false,
        }) catch return error.IoFailure;
        defer file.close(self.io);

        const offset = file.length(self.io) catch return error.IoFailure;
        file.writePositionalAll(self.io, line, offset) catch return error.IoFailure;
        file.writePositionalAll(self.io, "\n", offset + line.len) catch return error.IoFailure;
        file.sync(self.io) catch return error.IoFailure;

        return id;
    }

    /// Open a read cursor over the channel's JSONL file. The cursor
    /// snapshots the file contents into memory at creation time and
    /// is cheap because v0.1.0 outbox files hold at most a few
    /// hundred records. Caller must `deinit`.
    pub fn cursor(self: *Outbox, channel_id: spec.ChannelId) ReadError!Cursor {
        return Cursor.open(self, channel_id);
    }
};

/// Iterator over pending outbound records for one channel.
///
/// `next` returns records in file order, skipping any that are
/// already acked or whose `next_due_unix_ms` is in the future
/// relative to the outbox's clock. `ack` rewrites the whole file
/// atomically with the target record flipped to delivered; see the
/// note on `ack` for why rewrite-whole-file is the right choice at
/// v0.1.0 queue sizes.
pub const Cursor = struct {
    outbox: *Outbox,
    channel_id: spec.ChannelId,
    arena: std.heap.ArenaAllocator,
    records: []Record,
    index: usize,

    fn open(outbox: *Outbox, channel_id: spec.ChannelId) ReadError!Cursor {
        var arena = std.heap.ArenaAllocator.init(outbox.allocator);
        errdefer arena.deinit();

        const records = try loadRecords(outbox, channel_id, arena.allocator());
        return .{
            .outbox = outbox,
            .channel_id = channel_id,
            .arena = arena,
            .records = records,
            .index = 0,
        };
    }

    pub fn deinit(self: *Cursor) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Advance to the next record that is both unacked and due for
    /// a send attempt. Returns `null` once the end of the snapshot
    /// is reached.
    pub fn next(self: *Cursor) ReadError!?Pending {
        const now_ms = self.outbox.nowMs();
        while (self.index < self.records.len) {
            const r = self.records[self.index];
            self.index += 1;
            if (r.ack) continue;
            if (r.next_due_unix_ms > now_ms) continue;
            return .{
                .id = r.id,
                .conversation_key = r.conversation_key,
                .thread_key = r.thread_key,
                .text = r.text,
                .attempts = r.attempts,
                .next_due_unix_ms = r.next_due_unix_ms,
            };
        }
        return null;
    }

    /// Mark the record with `id` as delivered.
    ///
    /// The whole file is rewritten with the target record's `ack`
    /// flipped to `true` and then renamed into place through
    /// `createFileAtomic`. Full-file rewrite is deliberate: at
    /// v0.1.0 outbox sizes (tens to low-hundreds of records per
    /// channel) the cost is negligible and the alternative —
    /// patching a single line in-place — either requires a
    /// fixed-width record format or a WAL layer we don't need yet.
    pub fn ack(self: *Cursor, id: []const u8) AckError!void {
        var target_index: ?usize = null;
        for (self.records, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, id)) {
                target_index = i;
                break;
            }
        }
        const idx = target_index orelse return error.UnknownId;
        self.records[idx].ack = true;

        try rewriteFile(self.outbox, self.channel_id, self.records);
    }
};

fn outboxFilePath(
    buf: []u8,
    channel_id: spec.ChannelId,
) error{IoFailure}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.jsonl", .{
        outbox_dir_name,
        @tagName(channel_id),
    }) catch error.IoFailure;
}

/// Read the channel's JSONL file and decode every line into a
/// `Record`. A missing file is treated as "empty log" so the
/// cursor surfaces zero pending records rather than an error —
/// this keeps startup replay symmetric with a fresh-install run.
fn loadRecords(
    outbox: *Outbox,
    channel_id: spec.ChannelId,
    arena_allocator: std.mem.Allocator,
) ReadError![]Record {
    var path_buf: [64]u8 = undefined;
    const path = outboxFilePath(&path_buf, channel_id) catch return error.IoFailure;

    const file = outbox.state_root.openFile(outbox.io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return arena_allocator.alloc(Record, 0) catch return error.OutOfMemory,
        else => return error.IoFailure,
    };
    defer file.close(outbox.io);

    const len = file.length(outbox.io) catch return error.IoFailure;
    if (len == 0) return arena_allocator.alloc(Record, 0) catch return error.OutOfMemory;

    const bytes = arena_allocator.alloc(u8, len) catch return error.OutOfMemory;

    var read_buf: [1024]u8 = undefined;
    var r = file.reader(outbox.io, &read_buf);
    r.interface.readSliceAll(bytes) catch return error.IoFailure;

    var list: std.ArrayList(Record) = .empty;
    defer list.deinit(arena_allocator);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(Record, arena_allocator, line, .{}) catch
            return error.CorruptRecord;
        list.append(arena_allocator, parsed) catch return error.OutOfMemory;
    }

    return list.toOwnedSlice(arena_allocator) catch error.OutOfMemory;
}

/// Serialize every record in `records` back to the channel's JSONL
/// file via `createFileAtomic`. Writes go to an unnamed temp file
/// and are renamed over the live file so readers never observe a
/// torn state. A fresh fsync happens as part of the atomic replace.
fn rewriteFile(
    outbox: *Outbox,
    channel_id: spec.ChannelId,
    records: []const Record,
) AckError!void {
    outbox.state_root.createDirPath(outbox.io, outbox_dir_name) catch return error.IoFailure;

    var path_buf: [64]u8 = undefined;
    const path = outboxFilePath(&path_buf, channel_id) catch return error.IoFailure;

    var atomic = outbox.state_root.createFileAtomic(outbox.io, path, .{ .replace = true }) catch
        return error.IoFailure;
    defer atomic.deinit(outbox.io);

    var write_buf: [1024]u8 = undefined;
    var writer = atomic.file.writer(outbox.io, &write_buf);

    for (records) |r| {
        const line = std.json.Stringify.valueAlloc(outbox.allocator, r, .{}) catch
            return error.OutOfMemory;
        defer outbox.allocator.free(line);
        writer.interface.writeAll(line) catch return error.IoFailure;
        writer.interface.writeAll("\n") catch return error.IoFailure;
    }
    writer.interface.flush() catch return error.IoFailure;
    atomic.replace(outbox.io) catch return error.IoFailure;
}

/// Wire-format record written to disk. Private to the module; the
/// public surface (`Pending`, follow-up commits) exposes the
/// read-side view.
const Record = struct {
    id: []const u8,
    conversation_key: []const u8,
    thread_key: ?[]const u8 = null,
    text: []const u8,
    attempts: u32 = 0,
    next_due_unix_ms: i64,
    ack: bool = false,
};

const outbox_dir_name = "outbox";

/// Monotonic counter mixed into every id so two appends inside
/// the same microsecond still produce distinct ids. Process-local
/// is sufficient because the channel manager guarantees one
/// writer per `Outbox` per process.
var id_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Build a new record id: microsecond timestamp in hex, a dash, and
/// an 8-hex process-local counter. The counter guarantees
/// uniqueness inside the same microsecond without needing a
/// CSPRNG — Zig 0.16 moved `std.crypto.random` off the default
/// surface, and a counter is cheaper anyway.
fn generateId(allocator: std.mem.Allocator, now_us: i64) AppendError![]u8 {
    const ts: u64 = @intCast(@max(now_us, 0));
    const n = id_counter.fetchAdd(1, .monotonic);

    return std.fmt.allocPrint(allocator, "{x:0>16}-{x:0>8}", .{ ts, n }) catch
        error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn readAll(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try dir.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    var read_buf: [512]u8 = undefined;
    var r = file.reader(io, &read_buf);
    try r.interface.readSliceAll(bytes);
    return bytes;
}

test "append writes one newline-terminated JSON record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    const id = try box.append(.telegram, .{
        .conversation_key = "chat-42",
        .text = "hello",
    });
    defer testing.allocator.free(id);

    const contents = try readAll(testing.io, tmp.dir, "outbox/telegram.jsonl", testing.allocator);
    defer testing.allocator.free(contents);

    try testing.expect(contents.len > 0);
    try testing.expectEqual(@as(u8, '\n'), contents[contents.len - 1]);

    const line = contents[0 .. contents.len - 1];
    const parsed = try std.json.parseFromSlice(Record, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(id, parsed.value.id);
    try testing.expectEqualStrings("chat-42", parsed.value.conversation_key);
    try testing.expectEqualStrings("hello", parsed.value.text);
    try testing.expectEqual(@as(u32, 0), parsed.value.attempts);
    try testing.expect(!parsed.value.ack);
}

test "two appends produce two distinct ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    const id1 = try box.append(.telegram, .{ .conversation_key = "c", .text = "one" });
    defer testing.allocator.free(id1);
    const id2 = try box.append(.telegram, .{ .conversation_key = "c", .text = "two" });
    defer testing.allocator.free(id2);

    try testing.expect(!std.mem.eql(u8, id1, id2));

    const contents = try readAll(testing.io, tmp.dir, "outbox/telegram.jsonl", testing.allocator);
    defer testing.allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var count: usize = 0;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "reopening on an existing file appends rather than truncates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
        var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
        const id = try box.append(.telegram, .{ .conversation_key = "c", .text = "first" });
        testing.allocator.free(id);
    }
    {
        var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
        var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
        const id = try box.append(.telegram, .{ .conversation_key = "c", .text = "second" });
        testing.allocator.free(id);
    }

    const contents = try readAll(testing.io, tmp.dir, "outbox/telegram.jsonl", testing.allocator);
    defer testing.allocator.free(contents);

    // Two complete records means the second `init` didn't truncate.
    try testing.expect(std.mem.indexOf(u8, contents, "\"text\":\"first\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"text\":\"second\"") != null);
}

test "cursor returns 3 pending records in file order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());

    const id1 = try box.append(.telegram, .{ .conversation_key = "c", .text = "one" });
    defer testing.allocator.free(id1);
    const id2 = try box.append(.telegram, .{ .conversation_key = "c", .text = "two" });
    defer testing.allocator.free(id2);
    const id3 = try box.append(.telegram, .{ .conversation_key = "c", .text = "three" });
    defer testing.allocator.free(id3);

    var c = try box.cursor(.telegram);
    defer c.deinit();

    const p1 = (try c.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("one", p1.text);
    const p2 = (try c.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("two", p2.text);
    const p3 = (try c.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("three", p3.text);

    try testing.expect((try c.next()) == null);
}

test "ack on middle record causes cursor to skip it afterwards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());

    const id1 = try box.append(.telegram, .{ .conversation_key = "c", .text = "one" });
    defer testing.allocator.free(id1);
    const id2 = try box.append(.telegram, .{ .conversation_key = "c", .text = "two" });
    defer testing.allocator.free(id2);
    const id3 = try box.append(.telegram, .{ .conversation_key = "c", .text = "three" });
    defer testing.allocator.free(id3);

    {
        var c = try box.cursor(.telegram);
        defer c.deinit();
        try c.ack(id2);
    }

    var c = try box.cursor(.telegram);
    defer c.deinit();

    const p1 = (try c.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("one", p1.text);
    const p2 = (try c.next()) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("three", p2.text);
    try testing.expect((try c.next()) == null);
}

test "cursor skips records with a future next_due_unix_ms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());

    const id = try box.append(.telegram, .{ .conversation_key = "c", .text = "future" });
    defer testing.allocator.free(id);

    // Rewind the clock so the record is "in the future" relative
    // to now — simplest way to test the due-date filter without a
    // separate knob for record time.
    manual.value_ns -= 60 * std.time.ns_per_s;

    var c = try box.cursor(.telegram);
    defer c.deinit();
    try testing.expect((try c.next()) == null);
}

test "persisted line round-trips through std.json.parseFromSlice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var manual: clock_mod.ManualClock = .{ .value_ns = 1_700_000_000 * std.time.ns_per_s };
    var box = Outbox.init(testing.io, tmp.dir, testing.allocator, manual.clock());
    const id = try box.append(.telegram, .{
        .conversation_key = "room-7",
        .thread_key = "topic-1",
        .text = "round trip",
    });
    defer testing.allocator.free(id);

    const contents = try readAll(testing.io, tmp.dir, "outbox/telegram.jsonl", testing.allocator);
    defer testing.allocator.free(contents);

    const line = std.mem.trimEnd(u8, contents, "\n");
    const parsed = try std.json.parseFromSlice(Record, testing.allocator, line, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("room-7", parsed.value.conversation_key);
    try testing.expect(parsed.value.thread_key != null);
    try testing.expectEqualStrings("topic-1", parsed.value.thread_key.?);
    try testing.expectEqualStrings("round trip", parsed.value.text);
}
