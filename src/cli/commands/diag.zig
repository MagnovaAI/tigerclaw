//! `tigerclaw diag` — inspect recent diagnostic events.
//!
//! v0.1.0 surface: reads the on-disk diagnostics dump written by the
//! gateway at
//! `~/.tigerclaw/instances/default/sessions/default/diagnostics.jsonl`
//! (one JSON event per line). The runtime has an in-process buffer that
//! future commits will expose over HTTP; until that ships, the file is the
//! authoritative read-side source.
//!
//! Sub-verbs:
//!
//!   tail [--lines N]    print the last N events as a short table
//!                       (default 50). Missing file → "no events yet".
//!   show <event-id>     pretty-print the single event whose `id`
//!                       matches. Missing file or unknown id →
//!                       `error.NotFound`.
//!
//! Path override: callers may pass a non-null `path` in the args
//! struct so tests can point at a tmpdir-backed file instead of the
//! real state directory.

const std = @import("std");

pub const Subcommand = union(enum) {
    tail: TailArgs,
    show: ShowArgs,
};

pub const TailArgs = struct {
    lines: u32 = 50,
    /// Optional absolute path override. When null, the runner
    /// resolves the default instance diagnostics file.
    path: ?[]const u8 = null,
};

pub const ShowArgs = struct {
    id: []const u8,
    path: ?[]const u8 = null,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
    MissingEventId,
    InvalidLineCount,
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    const first = argv[0];
    if (std.mem.eql(u8, first, "tail")) return parseTail(argv[1..]);
    if (std.mem.eql(u8, first, "show")) return parseShow(argv[1..]);
    return error.UnknownSubcommand;
}

fn parseTail(rest: []const []const u8) ParseError!Subcommand {
    var args: TailArgs = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--lines") or std.mem.eql(u8, flag, "-n")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.lines = std.fmt.parseInt(u32, rest[i], 10) catch return error.InvalidLineCount;
        } else {
            return error.UnknownFlag;
        }
    }
    return .{ .tail = args };
}

fn parseShow(rest: []const []const u8) ParseError!Subcommand {
    if (rest.len == 0) return error.MissingEventId;
    return .{ .show = .{ .id = rest[0] } };
}

pub const Error = error{
    FileReadFailed,
    NotFound,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Soft cap on diagnostic file size. The runtime is expected to
/// rotate before this hits; treating the cap as a hard failure keeps
/// a runaway writer from blowing up the CLI.
pub const max_bytes: usize = 1 * 1024 * 1024;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    switch (cmd) {
        .tail => |a| try runTail(allocator, io, a, out, err),
        .show => |a| try runShow(allocator, io, a, out, err),
    }
}

fn runTail(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: TailArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    const path = args.path orelse {
        try err.writeAll("diag: no path override and $HOME resolution is main.zig's job\n");
        return error.FileReadFailed;
    };

    const bytes = readOrMissing(allocator, io, path) catch |e| switch (e) {
        error.FileMissing => {
            try out.writeAll("no diagnostics events yet\n");
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileReadFailed,
    };
    defer allocator.free(bytes);

    // Collect non-empty line slices into a ring; keep only the last N.
    var tail_buf = try allocator.alloc([]const u8, args.lines);
    defer allocator.free(tail_buf);
    var head: usize = 0;
    var count: usize = 0;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        tail_buf[head] = line;
        head = (head + 1) % args.lines;
        if (count < args.lines) count += 1;
    }

    if (count == 0) {
        try out.writeAll("no diagnostics events yet\n");
        return;
    }

    try out.writeAll("  ID                    LEVEL    MESSAGE\n");
    // Print oldest → newest so the terminal's natural scroll matches
    // chronological order.
    const start = if (count < args.lines) 0 else head;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (start + i) % args.lines;
        try writeRow(allocator, tail_buf[idx], out);
    }
}

fn writeRow(
    allocator: std.mem.Allocator,
    line: []const u8,
    out: *std.Io.Writer,
) Error!void {
    // Tolerate lines that aren't parseable JSON: render them raw so
    // the operator sees something rather than a silent drop.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        try out.print("  {s}\n", .{line});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try out.print("  {s}\n", .{line});
        return;
    }
    const id = stringField(parsed.value, "id") orelse "-";
    const level = stringField(parsed.value, "level") orelse "info";
    const message = stringField(parsed.value, "message") orelse "-";
    try out.print("  {s}", .{id});
    try padTo(out, id.len, 22);
    try out.print("{s}", .{level});
    try padTo(out, level.len, 9);
    try out.print("{s}\n", .{message});
}

fn padTo(w: *std.Io.Writer, already: usize, target: usize) std.Io.Writer.Error!void {
    if (already >= target) {
        try w.writeByte(' ');
        return;
    }
    var i: usize = 0;
    while (i < target - already) : (i += 1) try w.writeByte(' ');
}

fn stringField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = v.object.get(name) orelse return null;
    if (f != .string) return null;
    return f.string;
}

fn runShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ShowArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    const path = args.path orelse {
        try err.writeAll("diag: no path override and $HOME resolution is main.zig's job\n");
        return error.FileReadFailed;
    };

    const bytes = readOrMissing(allocator, io, path) catch |e| switch (e) {
        error.FileMissing => {
            try err.writeAll("no diagnostics events yet\n");
            return error.NotFound;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileReadFailed,
    };
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id = stringField(parsed.value, "id") orelse continue;
        if (!std.mem.eql(u8, id, args.id)) continue;

        // Pretty-print by re-emitting the parsed value with indentation.
        var pretty: std.Io.Writer.Allocating = .init(allocator);
        defer pretty.deinit();
        try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &pretty.writer);
        try out.writeAll(pretty.written());
        try out.writeByte('\n');
        return;
    }

    try err.print("diag: no event with id '{s}'\n", .{args.id});
    return error.NotFound;
}

const ReadOrMissingError = error{ FileMissing, FileReadFailed } || std.mem.Allocator.Error;

fn readOrMissing(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ReadOrMissingError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return error.FileMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileReadFailed,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "diag parse: tail default" {
    const argv = [_][]const u8{"tail"};
    const cmd = try parse(&argv);
    try testing.expectEqual(@as(u32, 50), cmd.tail.lines);
}

test "diag parse: tail --lines 10" {
    const argv = [_][]const u8{ "tail", "--lines", "10" };
    const cmd = try parse(&argv);
    try testing.expectEqual(@as(u32, 10), cmd.tail.lines);
}

test "diag parse: show <id>" {
    const argv = [_][]const u8{ "show", "evt-1" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("evt-1", cmd.show.id);
}

test "diag parse: show without id → MissingEventId" {
    const argv = [_][]const u8{"show"};
    try testing.expectError(error.MissingEventId, parse(&argv));
}

test "diag parse: unknown subverb" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(testing.io, name, .{});
    defer f.close(testing.io);
    var write_buf: [1024]u8 = undefined;
    var w = f.writer(testing.io, &write_buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn tmpAbsPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_abs);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_abs, name });
}

test "diag run tail: emits rows for each event in the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{"id":"evt-1","level":"info","message":"one"}
        \\{"id":"evt-2","level":"warn","message":"two"}
        \\{"id":"evt-3","level":"error","message":"three"}
        \\
    ;
    try writeTempFile(tmp.dir, "diagnostics.jsonl", body);

    const path = try tmpAbsPath(testing.allocator, tmp, "diagnostics.jsonl");
    defer testing.allocator.free(path);

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{ .tail = .{ .path = path } }, &out, &err);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "evt-1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "evt-2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "evt-3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "three") != null);
}

test "diag run tail: missing file prints the 'no events yet' message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAbsPath(testing.allocator, tmp, "does-not-exist.jsonl");
    defer testing.allocator.free(path);

    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .{ .tail = .{ .path = path } }, &out, &err);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "no diagnostics events yet") != null);
}

test "diag run tail: keeps only the last N events when lines < count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{"id":"evt-1","level":"info","message":"one"}
        \\{"id":"evt-2","level":"info","message":"two"}
        \\{"id":"evt-3","level":"info","message":"three"}
        \\
    ;
    try writeTempFile(tmp.dir, "diagnostics.jsonl", body);
    const path = try tmpAbsPath(testing.allocator, tmp, "diagnostics.jsonl");
    defer testing.allocator.free(path);

    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{ .tail = .{ .path = path, .lines = 2 } }, &out, &err);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "evt-1") == null);
    try testing.expect(std.mem.indexOf(u8, text, "evt-2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "evt-3") != null);
}

test "diag run show: surfaces the matching event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{"id":"evt-1","level":"info","message":"one"}
        \\{"id":"evt-2","level":"warn","message":"two"}
        \\
    ;
    try writeTempFile(tmp.dir, "diagnostics.jsonl", body);
    const path = try tmpAbsPath(testing.allocator, tmp, "diagnostics.jsonl");
    defer testing.allocator.free(path);

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{ .show = .{ .id = "evt-2", .path = path } }, &out, &err);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "\"evt-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "warn") != null);
}

test "diag run show: missing id returns NotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "diagnostics.jsonl",
        \\{"id":"evt-1"}
        \\
    );
    const path = try tmpAbsPath(testing.allocator, tmp, "diagnostics.jsonl");
    defer testing.allocator.free(path);

    var out_buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectError(
        error.NotFound,
        run(testing.allocator, testing.io, .{ .show = .{ .id = "nope", .path = path } }, &out, &err),
    );
}
