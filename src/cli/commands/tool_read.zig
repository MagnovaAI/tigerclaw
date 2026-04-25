//! Read a UTF-8 text file from the workspace, line-numbered for the
//! model, with an in-memory dedup table that suppresses repeat reads
//! of the same range.
//!
//! Format mirrors what frontier-coder models are trained on:
//!   "     1\u{2192}<line content>"
//! 6-space right-padded line number, U+2192 arrow, then the line.
//! Numbers >= 1_000_000 spill without padding.

const std = @import("std");

pub const ReadError = error{
    FileNotFound,
    FileTooLarge,
    InvalidPath,
    PathEscapesWorkspace,
    EmptyOffset,
    StatFailed,
    OpenFailed,
    ReadFailed,
    /// Bubbled from std.fmt.bufPrint when a line number overflows the
    /// 12-byte digit buffer. With i32 line numbers that's not reachable
    /// in practice, but the type-system needs it acknowledged.
    NoSpaceLeft,
} || std.mem.Allocator.Error;

pub const ReadOptions = struct {
    /// Workspace-relative path. Caller has already path-validated.
    path: []const u8,
    /// 1-based line offset. Default 1.
    offset: ?u32 = null,
    /// Max lines. Default DEFAULT_LIMIT_LINES.
    limit: ?u32 = null,
};

pub const TextRead = struct {
    /// Already line-numbered, owned. Empty when the slice is empty
    /// (legitimate -- file shorter than offset).
    content: []u8,
    /// Lines actually emitted (after offset/limit clamping).
    num_lines: u32,
    /// Total lines in the file.
    total_lines: u32,
    /// 1-based start line of the slice.
    start_line: u32,
    /// True when limit was hit before EOF.
    truncated: bool,
};

pub const ReadOutcome = union(enum) {
    text: TextRead,
    unchanged: struct { path: []const u8 },
    empty: struct { path: []const u8 },
    past_eof: struct {
        path: []const u8,
        total_lines: u32,
        requested_offset: u32,
    },

    pub fn deinit(self: ReadOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |t| allocator.free(t.content),
            else => {},
        }
    }
};

/// 256 KB total-file cap. Over -> FileTooLarge.
pub const MAX_FILE_BYTES: u64 = 256 * 1024;
/// Default max lines if limit unspecified.
pub const DEFAULT_LIMIT_LINES: u32 = 2000;
/// LRU cap per session.
pub const MAX_ENTRIES_PER_SESSION: usize = 256;

// ---------------------------------------------------------------------------
// State table

pub const ReadEntry = struct {
    /// File mtime ns at the time we cached this entry.
    mtime_ns: i128,
    /// File size at cache time. Used as a tiebreaker on filesystems
    /// where mtime resolution is too coarse to detect a same-second
    /// rewrite.
    size: u64,
    /// Offset that was requested.
    offset: u32,
    /// Limit that was requested (null = "no explicit limit"; keeps
    /// "default-2000" reads distinguishable from "limit=2000" reads
    /// for cache equality purposes -- pedantic but cheap).
    limit: ?u32,
    /// LRU sequence number, bumped on every access.
    seq: u64,
};

const PathMap = struct {
    entries: std.StringHashMapUnmanaged(ReadEntry) = .empty,
    next_seq: u64 = 0,

    pub fn deinit(self: *PathMap, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        self.entries.deinit(allocator);
    }
};

pub const ReadStateTable = struct {
    sessions: std.StringHashMapUnmanaged(PathMap) = .empty,

    pub fn init() ReadStateTable {
        return .{};
    }

    pub fn deinit(self: *ReadStateTable, allocator: std.mem.Allocator) void {
        var it = self.sessions.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.sessions.deinit(allocator);
    }

    /// Drop the cached entry for one (session, path) pair if any. Used
    /// after write_file/edit_file so the next read sees fresh content.
    pub fn invalidatePath(
        self: *ReadStateTable,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        canonical_path: []const u8,
    ) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        if (session.entries.fetchRemove(canonical_path)) |kv| {
            allocator.free(kv.key);
        }
    }

    /// Drop the entire cache for a session. Used after `bash` runs --
    /// any path could have been touched.
    pub fn invalidateSession(
        self: *ReadStateTable,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) void {
        const session = self.sessions.getPtr(session_id) orelse return;
        session.deinit(allocator);
        session.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Entry point

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *ReadStateTable,
    session_id: []const u8,
    workspace_root: []const u8,
    opts: ReadOptions,
) ReadError!ReadOutcome {
    const offset = opts.offset orelse 1;
    if (offset == 0) return error.EmptyOffset;
    const limit = opts.limit orelse DEFAULT_LIMIT_LINES;

    var root = openRoot(io, workspace_root) catch return error.FileNotFound;
    defer root.close(io);

    var file = root.openFile(io, opts.path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    const stat = file.stat(io) catch return error.StatFailed;
    if (stat.size > MAX_FILE_BYTES) return error.FileTooLarge;
    const mtime_ns: i128 = stat.mtime.toNanoseconds();
    const size: u64 = stat.size;

    const canonical = try canonicalPath(allocator, workspace_root, opts.path);
    // Hand canonical to recordRead/checkDedup. recordRead may keep it
    // as the entry key on insert; we must free it on every other path.
    var canonical_owned = canonical;
    var canonical_consumed = false;
    defer if (!canonical_consumed) allocator.free(canonical_owned);

    if (checkDedup(state, session_id, canonical_owned, offset, opts.limit, mtime_ns, size)) {
        return .{ .unchanged = .{ .path = opts.path } };
    }

    if (size == 0) {
        try recordRead(allocator, state, session_id, &canonical_owned, &canonical_consumed, offset, opts.limit, mtime_ns, size);
        return .{ .empty = .{ .path = opts.path } };
    }

    const raw = readEntireFile(allocator, io, file, size) catch return error.ReadFailed;
    defer allocator.free(raw);

    const total_lines = countLines(raw);
    if (offset > total_lines) {
        return .{ .past_eof = .{
            .path = opts.path,
            .total_lines = total_lines,
            .requested_offset = offset,
        } };
    }

    const slice = sliceLines(raw, offset, limit);
    const formatted = try formatLineNumbered(allocator, slice.content, offset);
    errdefer allocator.free(formatted);

    try recordRead(allocator, state, session_id, &canonical_owned, &canonical_consumed, offset, opts.limit, mtime_ns, size);

    const remaining = total_lines -| (offset - 1) -| slice.num_lines;
    return .{ .text = .{
        .content = formatted,
        .num_lines = slice.num_lines,
        .total_lines = total_lines,
        .start_line = offset,
        .truncated = remaining > 0,
    } };
}

fn openRoot(io: std.Io, workspace_root: []const u8) !std.Io.Dir {
    if (workspace_root.len == 0) return std.Io.Dir.cwd();
    return std.Io.Dir.cwd().openDir(io, workspace_root, .{});
}

/// Slurp `size` bytes from `file` into a freshly-allocated slice.
/// Caller frees. Loops on short reads -- positional read may return
/// less than requested even when the file isn't at EOF.
fn readEntireFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    size: u64,
) ![]u8 {
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    var off: u64 = 0;
    while (off < size) {
        const n = try file.readPositionalAll(io, buf[@intCast(off)..], off);
        if (n == 0) break;
        off += n;
    }
    return buf[0..@intCast(off)];
}

/// Build a workspace-anchored absolute key for the cache.
pub fn canonicalPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    rel: []const u8,
) ![]u8 {
    if (workspace_root.len == 0) return allocator.dupe(u8, rel);
    return std.fs.path.join(allocator, &.{ workspace_root, rel });
}

// ---------------------------------------------------------------------------
// Format helpers

/// Mirrors the reference `addLineNumbers`:
///   `${numStr.padStart(6, ' ')}\u{2192}${line}` for nums <= 999_999
///   `${numStr}\u{2192}${line}` for >= 1_000_000 (no padding, spills)
pub fn formatLineNumbered(
    allocator: std.mem.Allocator,
    content: []const u8,
    start_line: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_no: u32 = start_line;
    var iter = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var num_buf: [12]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{line_no});
        if (num_str.len < 6) {
            try out.appendNTimes(allocator, ' ', 6 - num_str.len);
        }
        try out.appendSlice(allocator, num_str);
        try out.appendSlice(allocator, "\u{2192}");
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;
        try out.appendSlice(allocator, trimmed);
        line_no += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn countLines(raw: []const u8) u32 {
    if (raw.len == 0) return 0;
    var n: u32 = 1;
    for (raw) |c| {
        if (c == '\n') n += 1;
    }
    if (raw[raw.len - 1] == '\n') n -= 1;
    return n;
}

pub const SliceResult = struct {
    content: []const u8,
    num_lines: u32,
};

pub fn sliceLines(raw: []const u8, offset_1based: u32, limit: u32) SliceResult {
    if (offset_1based == 0 or limit == 0) return .{ .content = "", .num_lines = 0 };

    var start: usize = 0;
    var skipped: u32 = 0;
    while (skipped < offset_1based - 1) : (skipped += 1) {
        const nl = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse {
            return .{ .content = "", .num_lines = 0 };
        };
        start = nl + 1;
    }
    if (start >= raw.len) return .{ .content = "", .num_lines = 0 };

    var end: usize = start;
    var taken: u32 = 0;
    while (taken < limit) {
        const nl = std.mem.indexOfScalarPos(u8, raw, end, '\n') orelse {
            end = raw.len;
            taken += 1;
            break;
        };
        end = nl + 1;
        taken += 1;
    }
    if (end > start and raw[end - 1] == '\n') end -= 1;

    return .{ .content = raw[start..end], .num_lines = taken };
}

// ---------------------------------------------------------------------------
// Dedup helpers

fn checkDedup(
    state: *ReadStateTable,
    session_id: []const u8,
    canonical: []const u8,
    offset: u32,
    limit: ?u32,
    mtime_ns: i128,
    size: u64,
) bool {
    const session = state.sessions.getPtr(session_id) orelse return false;
    const entry = session.entries.getPtr(canonical) orelse return false;
    if (entry.mtime_ns != mtime_ns) return false;
    if (entry.size != size) return false;
    if (entry.offset != offset) return false;
    if (entry.limit != limit) return false;
    session.next_seq += 1;
    entry.seq = session.next_seq;
    return true;
}

fn recordRead(
    allocator: std.mem.Allocator,
    state: *ReadStateTable,
    session_id: []const u8,
    canonical_io: *[]u8,
    canonical_consumed: *bool,
    offset: u32,
    limit: ?u32,
    mtime_ns: i128,
    size: u64,
) !void {
    // Get-or-create session.
    if (!state.sessions.contains(session_id)) {
        const owned_id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_id);
        try state.sessions.put(allocator, owned_id, .{});
    }
    const session = state.sessions.getPtr(session_id).?;

    session.next_seq += 1;
    const seq = session.next_seq;

    const gop = try session.entries.getOrPut(allocator, canonical_io.*);
    if (!gop.found_existing) {
        gop.key_ptr.* = canonical_io.*;
        canonical_consumed.* = true;
    }
    gop.value_ptr.* = .{
        .mtime_ns = mtime_ns,
        .size = size,
        .offset = offset,
        .limit = limit,
        .seq = seq,
    };

    if (session.entries.count() > MAX_ENTRIES_PER_SESSION) {
        evictOldest(allocator, session);
    }
}

fn evictOldest(allocator: std.mem.Allocator, session: *PathMap) void {
    var oldest_seq: u64 = std.math.maxInt(u64);
    var oldest_key: []const u8 = "";
    var it = session.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.seq < oldest_seq) {
            oldest_seq = kv.value_ptr.seq;
            oldest_key = kv.key_ptr.*;
        }
    }
    if (oldest_key.len > 0) {
        if (session.entries.fetchRemove(oldest_key)) |kv| {
            allocator.free(kv.key);
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "format: line numbers padded to 6 chars with arrow separator" {
    const out = try formatLineNumbered(testing.allocator, "hello\nworld", 1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("     1\u{2192}hello\n     2\u{2192}world", out);
}

test "format: line numbers >= 1_000_000 spill without padding" {
    const out = try formatLineNumbered(testing.allocator, "x", 1_234_567);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("1234567\u{2192}x", out);
}

test "format: CRLF stripped to LF" {
    const out = try formatLineNumbered(testing.allocator, "a\r\nb", 1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("     1\u{2192}a\n     2\u{2192}b", out);
}

test "countLines: empty / one line / trailing newline" {
    try testing.expectEqual(@as(u32, 0), countLines(""));
    try testing.expectEqual(@as(u32, 1), countLines("hi"));
    try testing.expectEqual(@as(u32, 1), countLines("hi\n"));
    try testing.expectEqual(@as(u32, 2), countLines("a\nb"));
    try testing.expectEqual(@as(u32, 2), countLines("a\nb\n"));
}

test "sliceLines: offset 1, limit 2 of 4-line input" {
    const r = sliceLines("a\nb\nc\nd", 1, 2);
    try testing.expectEqualStrings("a\nb", r.content);
    try testing.expectEqual(@as(u32, 2), r.num_lines);
}

test "sliceLines: offset 3, limit 10 returns last 2 lines" {
    const r = sliceLines("a\nb\nc\nd", 3, 10);
    try testing.expectEqualStrings("c\nd", r.content);
    try testing.expectEqual(@as(u32, 2), r.num_lines);
}

test "sliceLines: offset past EOF returns empty" {
    const r = sliceLines("a\nb", 10, 1);
    try testing.expectEqualStrings("", r.content);
    try testing.expectEqual(@as(u32, 0), r.num_lines);
}

test "ReadStateTable: invalidatePath drops single entry" {
    var state = ReadStateTable.init();
    defer state.deinit(testing.allocator);

    // Manually seed an entry to sidestep the file IO.
    const sess_owned = try testing.allocator.dupe(u8, "sess1");
    errdefer testing.allocator.free(sess_owned);
    try state.sessions.put(testing.allocator, sess_owned, .{});
    const session = state.sessions.getPtr("sess1").?;
    const key = try testing.allocator.dupe(u8, "/tmp/foo");
    try session.entries.put(testing.allocator, key, .{
        .mtime_ns = 0,
        .size = 0,
        .offset = 1,
        .limit = null,
        .seq = 1,
    });
    try testing.expect(session.entries.contains("/tmp/foo"));
    state.invalidatePath(testing.allocator, "sess1", "/tmp/foo");
    try testing.expect(!session.entries.contains("/tmp/foo"));
}
