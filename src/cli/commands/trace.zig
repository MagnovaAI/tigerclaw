//! `tigerclaw trace` — inspect and diff recorded traces.
//!
//! Traces are JSON-lines files emitted by the trace recorder: line one is
//! a `schema.Envelope`, every subsequent line is a `span.Span`. This
//! verb is a read-side ops tool — it lists trace files, renders a per-
//! span summary, and diffs two traces using the structural diff in
//! `src/trace/diff.zig`.

const std = @import("std");
const trace = @import("../../trace/root.zig");
const presentation = @import("../presentation.zig");

pub const Subcommand = union(enum) {
    list: ListArgs,
    show: ShowArgs,
    diff: DiffArgs,
};

pub const ListArgs = struct {
    /// Directory to scan. The literal `~` prefix is expanded against
    /// `$HOME` at run time; absolute paths are used as-is.
    dir: []const u8 = "~/.tigerclaw/traces",
};

pub const ShowArgs = struct { path: []const u8 };
pub const DiffArgs = struct { a: []const u8, b: []const u8 };

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
    if (std.mem.eql(u8, first, "diff")) return parseDiff(argv[1..]);
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

fn parseDiff(rest: []const []const u8) ParseError!Subcommand {
    if (rest.len < 2) return error.MissingPath;
    return .{ .diff = .{ .a = rest[0], .b = rest[1] } };
}

pub const Error = error{
    DirNotFound,
    FileNotFound,
    InvalidTrace,
    ReadFailed,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

const max_trace_bytes: usize = 64 * 1024 * 1024;
const max_show_events: usize = 200;

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
        .diff => |a| try runDiff(allocator, io, a, out, err),
    }
}

fn runList(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ListArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    // Tilde expansion is intentionally not performed here — the
    // shell normally expands `~` before argv reaches the binary, and
    // the runtime cannot safely read $HOME without a process env
    // handle plumbed through. Callers wanting the default location
    // pass the absolute path via --dir.
    runListIn(allocator, io, std.Io.Dir.cwd(), args.dir, out) catch |e| switch (e) {
        error.DirNotFound => {
            try err.print("trace: directory not found: {s}\n", .{args.dir});
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
            !std.mem.endsWith(u8, entry.name, ".trace")) continue;

        const events = countEvents(allocator, io, dir, entry.name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        const stat = dir.statFile(io, entry.name, .{}) catch return error.ReadFailed;

        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);
        const summary = try std.fmt.allocPrint(
            allocator,
            "events={d} size={d}",
            .{ events, stat.size },
        );
        try rows.append(allocator, .{ .name = name_copy, .summary = summary });
    }

    std.mem.sort(Row, rows.items, {}, lessRow);

    try out.writeAll("  NAME                          EVENTS / SIZE\n");
    try presentation.writeTable(out, Row, rows.items, 28);
}

fn lessRow(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn countEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
) !usize {
    const bytes = dir.readFileAlloc(io, name, allocator, .limited(max_trace_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var nonempty: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) nonempty += 1;
    }
    // The first non-empty line is the envelope; the rest are spans.
    return if (nonempty == 0) 0 else nonempty - 1;
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
            try err.print("trace: file not found: {s}\n", .{args.path});
            return e;
        },
        error.InvalidTrace => {
            try err.print("trace: invalid trace: {s}\n", .{args.path});
            return e;
        },
        else => return e,
    };
}

fn runShowIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    path: []const u8,
    out: *std.Io.Writer,
) Error!void {
    const bytes = parent.readFileAlloc(io, path, allocator, .limited(max_trace_bytes)) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);

    var replay = trace.replayer.replayFromBytes(allocator, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTrace,
    };
    defer replay.deinit();

    try out.print(
        "trace {s} (run {s}, mode {s}, schema v{d})\n",
        .{
            replay.envelope.trace_id,
            replay.envelope.run_id,
            @tagName(replay.envelope.mode),
            replay.envelope.schema_version,
        },
    );

    const total = replay.spans.len;
    const shown = @min(total, max_show_events);
    for (replay.spans[0..shown]) |sp| {
        try out.print(
            "  {s:<18} {s:<24} t={d} status={s}\n",
            .{ @tagName(sp.kind), sp.name, sp.started_at_ns, @tagName(sp.status) },
        );
    }
    if (total > shown) {
        try out.print("(truncated, {d} more events)\n", .{total - shown});
    }
    try out.print("{d} spans\n", .{total});
}

fn runDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: DiffArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    var replay_a = try loadReplay(allocator, io, args.a, err);
    defer replay_a.deinit();
    var replay_b = try loadReplay(allocator, io, args.b, err);
    defer replay_b.deinit();

    const report = trace.diff.diff(allocator, replay_a.spans, replay_b.spans) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer report.deinit(allocator);

    if (report.empty()) {
        try out.print("no differences ({d} spans on each side)\n", .{replay_a.spans.len});
        return;
    }

    for (report.entries) |entry| {
        const sigil: u8 = switch (entry.kind) {
            .missing => '-',
            .extra => '+',
            .status => '~',
        };
        try out.print("{c} {s:<28} {s}\n", .{ sigil, entry.span_name, entry.detail });
    }
    try out.print("{d} differences\n", .{report.entries.len});
}

fn loadReplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    err: *std.Io.Writer,
) Error!trace.replayer.Replay {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_trace_bytes)) catch |e| switch (e) {
        error.FileNotFound => {
            try err.print("trace: file not found: {s}\n", .{path});
            return error.FileNotFound;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer allocator.free(bytes);

    return trace.replayer.replayFromBytes(allocator, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try err.print("trace: invalid trace: {s}\n", .{path});
            return error.InvalidTrace;
        },
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: list defaults" {
    const argv = [_][]const u8{"list"};
    const sub = try parse(&argv);
    try testing.expectEqualStrings("~/.tigerclaw/traces", sub.list.dir);
}

test "parse: list --dir overrides" {
    const argv = [_][]const u8{ "list", "--dir", "/tmp" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("/tmp", sub.list.dir);
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

test "parse: diff with both paths" {
    const argv = [_][]const u8{ "diff", "a.jsonl", "b.jsonl" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("a.jsonl", sub.diff.a);
    try testing.expectEqualStrings("b.jsonl", sub.diff.b);
}

test "parse: diff with only one path → MissingPath" {
    const argv = [_][]const u8{ "diff", "a.jsonl" };
    try testing.expectError(error.MissingPath, parse(&argv));
}

test "parse: unknown verb → UnknownSubcommand" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

fn writeTraceFile(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    contents: []const u8,
) !void {
    const file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

fn buildSyntheticTrace(allocator: std.mem.Allocator) ![]u8 {
    const envelope = trace.schema.Envelope{
        .trace_id = "trace-test",
        .run_id = "run-1",
        .started_at_ns = 1_700_000_000_000_000_000,
        .mode = .run,
    };
    const root_span = trace.span.Span{
        .id = "s0",
        .trace_id = "trace-test",
        .kind = .root,
        .name = "root",
        .started_at_ns = 0,
        .finished_at_ns = 100,
    };
    const turn = trace.span.Span{
        .id = "s1",
        .parent_id = "s0",
        .trace_id = "trace-test",
        .kind = .turn,
        .name = "turn-1",
        .started_at_ns = 10,
        .finished_at_ns = 90,
    };
    const tool = trace.span.Span{
        .id = "s2",
        .parent_id = "s1",
        .trace_id = "trace-test",
        .kind = .tool_call,
        .name = "read_file",
        .started_at_ns = 20,
        .finished_at_ns = 30,
    };

    const env_bytes = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    defer allocator.free(env_bytes);
    const a_bytes = try std.json.Stringify.valueAlloc(allocator, root_span, .{});
    defer allocator.free(a_bytes);
    const b_bytes = try std.json.Stringify.valueAlloc(allocator, turn, .{});
    defer allocator.free(b_bytes);
    const c_bytes = try std.json.Stringify.valueAlloc(allocator, tool, .{});
    defer allocator.free(c_bytes);

    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}\n",
        .{ env_bytes, a_bytes, b_bytes, c_bytes },
    );
}

test "runList: lists *.jsonl trace files in the target dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trace_bytes = try buildSyntheticTrace(testing.allocator);
    defer testing.allocator.free(trace_bytes);

    try writeTraceFile(testing.io, tmp.dir, "alpha.jsonl", trace_bytes);
    try writeTraceFile(testing.io, tmp.dir, "beta.jsonl", trace_bytes);
    try writeTraceFile(testing.io, tmp.dir, "ignored.txt", "no");

    var out_buf: [2048]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try runListIn(testing.allocator, testing.io, tmp.dir, ".", &ow);
    const out = ow.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "alpha.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "beta.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ignored.txt") == null);
}

test "runShow: synthetic trace renders all three span kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trace_bytes = try buildSyntheticTrace(testing.allocator);
    defer testing.allocator.free(trace_bytes);
    try writeTraceFile(testing.io, tmp.dir, "t.jsonl", trace_bytes);

    var out_buf: [4096]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    try runShowIn(testing.allocator, testing.io, tmp.dir, "t.jsonl", &ow);
    const out = ow.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "trace-test") != null);
    try testing.expect(std.mem.indexOf(u8, out, "root") != null);
    try testing.expect(std.mem.indexOf(u8, out, "turn") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tool_call") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3 spans") != null);
}

test "runDiff: a trace diffed against itself reports no differences" {
    const trace_bytes = try buildSyntheticTrace(testing.allocator);
    defer testing.allocator.free(trace_bytes);

    var replay_a = try trace.replayer.replayFromBytes(testing.allocator, trace_bytes);
    defer replay_a.deinit();
    var replay_b = try trace.replayer.replayFromBytes(testing.allocator, trace_bytes);
    defer replay_b.deinit();

    const report = try trace.diff.diff(testing.allocator, replay_a.spans, replay_b.spans);
    defer report.deinit(testing.allocator);
    try testing.expect(report.empty());
}
