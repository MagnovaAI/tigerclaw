//! `tigerclaw cassette` — inspect and replay VCR cassettes.
//!
//! Cassettes are recorded by the harness (run with TIGERCLAW_VCR_MODE
//! =record + the relevant API key env var); this CLI is a read-side
//! tool for ops to see what got captured and play it back through the
//! VCR replayer for a sanity check.
//!
//! v0.1.0 surface:
//!   list          — table of cassette files under tests/cassettes/
//!   show <path>   — header + per-interaction summary (method/url/status)
//!   replay <path> — load via replayer.replayFromBytes; print "ok" or
//!                   the first parse error.

const std = @import("std");
const cassette_mod = @import("../../vcr/cassette.zig");
const replayer = @import("../../vcr/replayer.zig");
const presentation = @import("../presentation.zig");

pub const Subcommand = union(enum) {
    list: ListArgs,
    show: ShowArgs,
    replay: ReplayArgs,
};

pub const ListArgs = struct {
    /// Directory to scan. Defaults to "tests/cassettes" relative to
    /// the cwd; in production we expect the gateway to point at its
    /// configured cassette dir.
    dir: []const u8 = "tests/cassettes",
};

pub const ShowArgs = struct { path: []const u8 };
pub const ReplayArgs = struct { path: []const u8 };

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
    MissingPath,
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    const first = argv[0];
    if (std.mem.eql(u8, first, "list")) return parseList(argv[1..]);
    if (std.mem.eql(u8, first, "show")) return parseShow(argv[1..]);
    if (std.mem.eql(u8, first, "replay")) return parseReplay(argv[1..]);
    return error.UnknownSubcommand;
}

fn parseList(rest: []const []const u8) ParseError!Subcommand {
    var args: ListArgs = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--dir")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.dir = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return .{ .list = args };
}

fn parseShow(rest: []const []const u8) ParseError!Subcommand {
    if (rest.len == 0) return error.MissingPath;
    return .{ .show = .{ .path = rest[0] } };
}

fn parseReplay(rest: []const []const u8) ParseError!Subcommand {
    if (rest.len == 0) return error.MissingPath;
    return .{ .replay = .{ .path = rest[0] } };
}

pub const Error = error{
    DirNotFound,
    FileNotFound,
    InvalidCassette,
    ReadFailed,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    switch (cmd) {
        .list => |a| try runList(allocator, io, a, out, err),
        .show => |a| try runShow(allocator, io, a, out, err),
        .replay => |a| try runReplay(allocator, io, a, out, err),
    }
}

fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ListArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    runListIn(allocator, io, std.Io.Dir.cwd(), args.dir, out) catch |e| switch (e) {
        error.DirNotFound => {
            try err.print("cassette: directory not found: {s}\n", .{args.dir});
            return e;
        },
        else => return e,
    };
}

const Row = struct { name: []const u8, summary: []const u8 };

fn runListIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    out: *std.Io.Writer,
) Error!void {
    var dir = parent.openDir(io, sub_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return error.DirNotFound,
        else => return error.ReadFailed,
    };
    defer dir.close(io);

    var rows: std.array_list.Aligned(Row, null) = .empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row.name);
            allocator.free(row.summary);
        }
        rows.deinit(allocator);
    }

    var walker = dir.iterate();
    while (walker.next(io) catch return error.ReadFailed) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl") and
            !std.mem.endsWith(u8, entry.name, ".cassette")) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch return error.ReadFailed;
        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);
        const size_str = try std.fmt.allocPrint(allocator, "{d}", .{stat.size});
        try rows.append(allocator, .{ .name = name_copy, .summary = size_str });
    }

    std.mem.sort(Row, rows.items, {}, lessRow);

    try out.writeAll("  NAME                          SIZE\n");
    try presentation.writeTable(out, Row, rows.items, 28);
}

fn lessRow(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn runShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ShowArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    runShowIn(allocator, io, std.Io.Dir.cwd(), args.path, out) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("cassette: file not found: {s}\n", .{args.path});
            return e;
        },
        error.InvalidCassette => {
            try err.print("cassette: invalid cassette: {s}\n", .{args.path});
            return e;
        },
        else => return e,
    };
}

const max_cassette_bytes: usize = 16 * 1024 * 1024;

fn runShowIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    path: []const u8,
    out: *std.Io.Writer,
) Error!void {
    const bytes = parent.readFileAlloc(io, path, allocator, .limited(max_cassette_bytes)) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    const header_line = nextNonEmpty(&lines) orelse return error.InvalidCassette;
    const header_parsed = std.json.parseFromSlice(
        cassette_mod.Header,
        allocator,
        header_line,
        .{},
    ) catch return error.InvalidCassette;
    defer header_parsed.deinit();

    try out.print("cassette {s} (format v{d})\n", .{
        header_parsed.value.cassette_id,
        header_parsed.value.format_version,
    });

    var count: usize = 0;
    while (nextNonEmpty(&lines)) |line| {
        const parsed = std.json.parseFromSlice(
            cassette_mod.Interaction,
            allocator,
            line,
            .{},
        ) catch return error.InvalidCassette;
        defer parsed.deinit();
        try out.print("  {s} {s} -> {d}\n", .{
            parsed.value.request.method,
            parsed.value.request.url,
            parsed.value.response.status,
        });
        count += 1;
    }

    try out.print("{d} interactions\n", .{count});
}

fn runReplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ReplayArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        args.path,
        allocator,
        .limited(max_cassette_bytes),
    ) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("cassette: file not found: {s}\n", .{args.path});
            return error.FileNotFound;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);

    var cs = replayer.replayFromBytes(allocator, bytes) catch |e| {
        try err.print("cassette: replay failed: {s}\n", .{@errorName(e)});
        return error.InvalidCassette;
    };
    defer cs.deinit();

    try out.print("ok ({d} interactions)\n", .{cs.interactions.len});
}

fn nextNonEmpty(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |line| {
        if (line.len > 0) return line;
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: list defaults" {
    const argv = [_][]const u8{"list"};
    const sub = try parse(&argv);
    try testing.expectEqualStrings("tests/cassettes", sub.list.dir);
}

test "parse: list --dir overrides" {
    const argv = [_][]const u8{ "list", "--dir", "/tmp/c" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("/tmp/c", sub.list.dir);
}

test "parse: show with path" {
    const argv = [_][]const u8{ "show", "/tmp/x.jsonl" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("/tmp/x.jsonl", sub.show.path);
}

test "parse: show without path → MissingPath" {
    const argv = [_][]const u8{"show"};
    try testing.expectError(error.MissingPath, parse(&argv));
}

test "parse: replay with path" {
    const argv = [_][]const u8{ "replay", "/tmp/x.jsonl" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("/tmp/x.jsonl", sub.replay.path);
}

test "parse: unknown verb → UnknownSubcommand" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

test "parse: empty argv → MissingSubcommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubcommand, parse(&argv));
}

fn writeCassetteFile(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    contents: []const u8,
) !void {
    const file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

test "runList: lists *.jsonl files in the target dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCassetteFile(testing.io, tmp.dir, "alpha.jsonl", "x");
    try writeCassetteFile(testing.io, tmp.dir, "beta.jsonl", "yy");
    try writeCassetteFile(testing.io, tmp.dir, "ignored.txt", "no");

    var out_buf: [1024]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try runListIn(testing.allocator, testing.io, tmp.dir, ".", &ow);
    const out = ow.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "alpha.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "beta.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ignored.txt") == null);
}

test "runList: missing dir → DirNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf: [128]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(
        error.DirNotFound,
        runListIn(testing.allocator, testing.io, tmp.dir, "no_such_dir", &ow),
    );
}

test "runShow: synthetic cassette renders one interaction line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = cassette_mod.Header{
        .cassette_id = "test-cassette",
        .created_at_ns = 1_700_000_000_000_000_000,
    };
    const interaction = cassette_mod.Interaction{
        .request = .{ .method = "GET", .url = "https://x.test/v1/ping" },
        .response = .{ .status = 200, .body = "{}" },
    };

    const header_bytes = try std.json.Stringify.valueAlloc(testing.allocator, header, .{});
    defer testing.allocator.free(header_bytes);
    const inter_bytes = try std.json.Stringify.valueAlloc(testing.allocator, interaction, .{});
    defer testing.allocator.free(inter_bytes);

    const contents = try std.fmt.allocPrint(
        testing.allocator,
        "{s}\n{s}\n",
        .{ header_bytes, inter_bytes },
    );
    defer testing.allocator.free(contents);

    try writeCassetteFile(testing.io, tmp.dir, "c.jsonl", contents);

    var out_buf: [2048]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try runShowIn(testing.allocator, testing.io, tmp.dir, "c.jsonl", &ow);
    const out = ow.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "test-cassette") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GET") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://x.test/v1/ping") != null);
    try testing.expect(std.mem.indexOf(u8, out, "200") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 interactions") != null);
}

test "runShow: garbage on line 1 → InvalidCassette" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCassetteFile(testing.io, tmp.dir, "bad.jsonl", "not-json\n");

    var out_buf: [256]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try testing.expectError(
        error.InvalidCassette,
        runShowIn(testing.allocator, testing.io, tmp.dir, "bad.jsonl", &ow),
    );
}
