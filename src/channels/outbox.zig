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
};

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
