//! Append-only log-file sink for the gateway daemon.
//!
//! The daemon writes structured event lines to a single file on
//! disk. A `LogSink` owns the open file and a byte offset that
//! tracks the next append position. Each `append` issues a single
//! positional write; that keeps the implementation allocation-free
//! and matches the `std.Io.File` surface that is available in
//! Zig 0.16 (no streaming writer + seek combo).
//!
//! Rotation, ringing, and log-level filtering live higher up; this
//! module just owns the file.

const std = @import("std");

pub const OpenError = error{
    IoFailure,
};

pub const WriteError = error{
    IoFailure,
};

pub const LogSink = struct {
    file: std.Io.File,
    offset: u64,
    io: std.Io,

    /// Open `path` inside `dir` for append. Creates the file when
    /// missing; when present, further writes land at the existing
    /// end-of-file. Caller owns the returned sink and must call
    /// `close`.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) OpenError!LogSink {
        const file = dir.createFile(io, path, .{
            .truncate = false,
            .read = false,
        }) catch return error.IoFailure;

        const len = file.length(io) catch {
            file.close(io);
            return error.IoFailure;
        };
        return .{ .file = file, .offset = len, .io = io };
    }

    pub fn close(self: *LogSink) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Append a single log line. A trailing `\n` is added if the
    /// caller did not supply one.
    pub fn append(self: *LogSink, line: []const u8) WriteError!void {
        self.file.writePositionalAll(self.io, line, self.offset) catch return error.IoFailure;
        self.offset += line.len;

        const needs_nl = line.len == 0 or line[line.len - 1] != '\n';
        if (needs_nl) {
            self.file.writePositionalAll(self.io, "\n", self.offset) catch return error.IoFailure;
            self.offset += 1;
        }
    }

    /// Flush buffered writes to disk. Positional writes are already
    /// flushed on return, so this is a no-op kept for symmetry with
    /// sinks that accumulate in memory.
    pub fn flush(_: *LogSink) WriteError!void {}
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn readBack(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try dir.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    var read_buf: [256]u8 = undefined;
    var r = file.reader(io, &read_buf);
    try r.interface.readSliceAll(bytes);
    return bytes;
}

test "LogSink: append writes a newline-terminated line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink = try LogSink.open(testing.io, tmp.dir, "gateway.log");
    try sink.append("hello");
    sink.close();

    const contents = try readBack(testing.io, tmp.dir, "gateway.log", testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("hello\n", contents);
}

test "LogSink: preserves a caller-supplied trailing newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink = try LogSink.open(testing.io, tmp.dir, "gateway.log");
    try sink.append("already-newlined\n");
    sink.close();

    const contents = try readBack(testing.io, tmp.dir, "gateway.log", testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("already-newlined\n", contents);
}

test "LogSink: second open appends instead of truncating" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var sink = try LogSink.open(testing.io, tmp.dir, "gateway.log");
        try sink.append("first");
        sink.close();
    }
    {
        var sink = try LogSink.open(testing.io, tmp.dir, "gateway.log");
        try sink.append("second");
        sink.close();
    }

    const contents = try readBack(testing.io, tmp.dir, "gateway.log", testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("first\nsecond\n", contents);
}

test "LogSink: multiple appends within one session concatenate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink = try LogSink.open(testing.io, tmp.dir, "gateway.log");
    try sink.append("one");
    try sink.append("two");
    try sink.append("three");
    sink.close();

    const contents = try readBack(testing.io, tmp.dir, "gateway.log", testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("one\ntwo\nthree\n", contents);
}
