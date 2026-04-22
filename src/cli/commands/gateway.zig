//! `tigerclaw gateway <verb>` sub-verb parser.
//!
//! Sub-verbs mirror the common daemon control surface:
//!
//!   start   — launch the daemon (optional `--foreground` / `--detach`)
//!   stop    — SIGTERM the running daemon and wait for drain
//!   status  — print health + in-flight counter + PID
//!   restart — stop then start with the same options
//!   logs    — tail the daemon log file
//!   serve   — run the gateway in the foreground regardless of config
//!
//! Execution lives next to the daemon + HTTP client. This module is
//! argv-only. The parser intentionally rejects unknown flags so a
//! typo surfaces as a clear usage error rather than silently falling
//! through to the default behaviour.

const std = @import("std");

pub const Verb = union(enum) {
    start: StartOptions,
    stop,
    status,
    restart: StartOptions,
    logs: LogsOptions,
    serve: StartOptions,
};

pub const StartOptions = struct {
    /// When true, keep the gateway attached to the current terminal.
    /// Mutually exclusive with `detach`.
    foreground: bool = false,
    /// When true, fork + detach into a background daemon.
    detach: bool = false,
};

pub const LogsOptions = struct {
    /// When true, follow the log file (`tail -f` style).
    follow: bool = false,
    /// Number of trailing lines to print before (optionally) following.
    /// Zero means "all available".
    tail: u32 = 0,
};

pub const ParseError = error{
    MissingSubVerb,
    UnknownSubVerb,
    UnknownFlag,
    MissingFlagValue,
    InvalidTailCount,
    ConflictingFlags,
};

pub fn parse(argv: []const []const u8) ParseError!Verb {
    if (argv.len == 0) return error.MissingSubVerb;

    const sub = argv[0];
    const rest = argv[1..];

    if (std.mem.eql(u8, sub, "start")) {
        return .{ .start = try parseStartOptions(rest) };
    }
    if (std.mem.eql(u8, sub, "restart")) {
        return .{ .restart = try parseStartOptions(rest) };
    }
    if (std.mem.eql(u8, sub, "serve")) {
        return .{ .serve = try parseStartOptions(rest) };
    }
    if (std.mem.eql(u8, sub, "stop")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .stop;
    }
    if (std.mem.eql(u8, sub, "status")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .status;
    }
    if (std.mem.eql(u8, sub, "logs")) {
        return .{ .logs = try parseLogsOptions(rest) };
    }
    return error.UnknownSubVerb;
}

fn parseStartOptions(argv: []const []const u8) ParseError!StartOptions {
    var opts: StartOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--foreground")) {
            opts.foreground = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--detach")) {
            opts.detach = true;
            continue;
        }
        return error.UnknownFlag;
    }
    if (opts.foreground and opts.detach) return error.ConflictingFlags;
    return opts;
}

fn parseLogsOptions(argv: []const []const u8) ParseError!LogsOptions {
    var opts: LogsOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f")) {
            opts.follow = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--tail") or std.mem.eql(u8, a, "-n")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            const raw = argv[i + 1];
            const n = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidTailCount;
            opts.tail = n;
            i += 1;
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

// ---------------------------------------------------------------------------
// `logs` execution — read-side tailer for the daemon log file.

const builtin = @import("builtin");

pub const LogsRunOptions = struct {
    /// Absolute path to the log file. The main.zig dispatch resolves
    /// `$HOME/.tigerclaw/logs/gateway.log`; tests pass a tmpdir path.
    path: []const u8,
    follow: bool = false,
    /// Trailing lines to print before (optional) follow. Zero means
    /// "all of the current file".
    tail: u32 = 0,
};

pub const LogsError = error{
    FileReadFailed,
    Interrupted,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Soft cap. Gateway logs in v0.1.0 are ops breadcrumbs, not bulk
/// traffic — anything beyond 4MB is a misconfiguration and we'd
/// rather surface that than chew through memory silently.
pub const max_log_bytes: usize = 4 * 1024 * 1024;

/// Process-wide SIGINT flag for `--follow`. Mirrors the pattern in
/// `agent.zig` so both verbs behave identically under Ctrl-C.
pub var interrupt_requested: std.atomic.Value(bool) = .init(false);

pub fn resetInterruptForTesting() void {
    interrupt_requested.store(false, .release);
}

pub fn installInterruptHandler() void {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn handleSigint(_: std.c.SIG) callconv(.c) void {
    interrupt_requested.store(true, .release);
}

pub fn runLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LogsRunOptions,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) LogsError!void {
    const printed = printTail(allocator, io, opts.path, opts.tail, out, err) catch |e| switch (e) {
        error.FileMissing => {
            try out.print("no log file yet at {s}\n", .{opts.path});
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        else => return error.FileReadFailed,
    };

    if (!opts.follow) return;

    var last_size = printed;
    while (!interrupt_requested.load(.acquire)) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(500 * std.time.ns_per_ms), .awake) catch {};
        if (interrupt_requested.load(.acquire)) break;

        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            opts.path,
            allocator,
            .limited(max_log_bytes),
        ) catch |e| switch (e) {
            error.FileNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileReadFailed,
        };
        defer allocator.free(bytes);

        if (bytes.len < last_size) {
            // Rotation / truncation — emit the whole new file.
            try out.writeAll(bytes);
            last_size = bytes.len;
            continue;
        }
        if (bytes.len > last_size) {
            try out.writeAll(bytes[last_size..]);
            last_size = bytes.len;
        }
    }
    return error.Interrupted;
}

const PrintTailError = error{ FileMissing, FileReadFailed } || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Emits the last `tail` lines of the file (or the entire file when
/// `tail == 0`) and returns the total byte size consumed so a
/// follow-loop can start from the correct offset.
fn printTail(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    tail: u32,
    out: *std.Io.Writer,
    _: *std.Io.Writer,
) PrintTailError!usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_log_bytes),
    ) catch |e| switch (e) {
        error.FileNotFound => return error.FileMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileReadFailed,
    };
    defer allocator.free(bytes);

    if (tail == 0) {
        try out.writeAll(bytes);
        return bytes.len;
    }

    // Walk backwards counting newlines until we've seen `tail` of them
    // or hit the start. Using a byte cursor is cheaper than collecting
    // line slices for a file that's already fully in memory.
    var newlines_seen: u32 = 0;
    var cut: usize = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '\n') {
            newlines_seen += 1;
            // Stop once we've skipped past `tail` newlines — the next
            // char is the first byte of the first retained line.
            if (newlines_seen > tail) {
                cut = i + 1;
                break;
            }
        }
    }

    try out.writeAll(bytes[cut..]);
    return bytes.len;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: start with no flags" {
    const argv = [_][]const u8{"start"};
    const v = try parse(&argv);
    try testing.expect(!v.start.foreground);
    try testing.expect(!v.start.detach);
}

test "parse: start --foreground sets the flag" {
    const argv = [_][]const u8{ "start", "--foreground" };
    const v = try parse(&argv);
    try testing.expect(v.start.foreground);
    try testing.expect(!v.start.detach);
}

test "parse: start --detach sets the flag" {
    const argv = [_][]const u8{ "start", "--detach" };
    const v = try parse(&argv);
    try testing.expect(v.start.detach);
}

test "parse: start --foreground --detach is rejected" {
    const argv = [_][]const u8{ "start", "--foreground", "--detach" };
    try testing.expectError(error.ConflictingFlags, parse(&argv));
}

test "parse: stop takes no flags" {
    const argv = [_][]const u8{"stop"};
    const v = try parse(&argv);
    try testing.expectEqual(Verb.stop, v);
}

test "parse: stop with extra args rejects UnknownFlag" {
    const argv = [_][]const u8{ "stop", "--soft" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: status takes no flags" {
    const argv = [_][]const u8{"status"};
    const v = try parse(&argv);
    try testing.expectEqual(Verb.status, v);
}

test "parse: restart carries start options" {
    const argv = [_][]const u8{ "restart", "--detach" };
    const v = try parse(&argv);
    try testing.expect(v.restart.detach);
}

test "parse: logs default options" {
    const argv = [_][]const u8{"logs"};
    const v = try parse(&argv);
    try testing.expect(!v.logs.follow);
    try testing.expectEqual(@as(u32, 0), v.logs.tail);
}

test "parse: logs --follow + --tail 50" {
    const argv = [_][]const u8{ "logs", "--follow", "--tail", "50" };
    const v = try parse(&argv);
    try testing.expect(v.logs.follow);
    try testing.expectEqual(@as(u32, 50), v.logs.tail);
}

test "parse: logs -f and -n short forms" {
    const argv = [_][]const u8{ "logs", "-f", "-n", "5" };
    const v = try parse(&argv);
    try testing.expect(v.logs.follow);
    try testing.expectEqual(@as(u32, 5), v.logs.tail);
}

test "parse: logs --tail without a value returns MissingFlagValue" {
    const argv = [_][]const u8{ "logs", "--tail" };
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "parse: logs --tail with a non-integer returns InvalidTailCount" {
    const argv = [_][]const u8{ "logs", "--tail", "lots" };
    try testing.expectError(error.InvalidTailCount, parse(&argv));
}

test "parse: empty argv returns MissingSubVerb" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubVerb, parse(&argv));
}

test "parse: unknown sub-verb returns UnknownSubVerb" {
    const argv = [_][]const u8{"launch"};
    try testing.expectError(error.UnknownSubVerb, parse(&argv));
}

test "parse: serve carries start options" {
    const argv = [_][]const u8{ "serve", "--foreground" };
    const v = try parse(&argv);
    try testing.expect(v.serve.foreground);
}

fn writeTempLog(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(testing.io, name, .{});
    defer f.close(testing.io);
    var write_buf: [1024]u8 = undefined;
    var w = f.writer(testing.io, &write_buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn tmpAbsLogPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_abs);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_abs, name });
}

test "runLogs: tail N prints only the last N lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempLog(tmp.dir, "g.log", "one\ntwo\nthree\nfour\nfive\n");
    const path = try tmpAbsLogPath(testing.allocator, tmp, "g.log");
    defer testing.allocator.free(path);

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try runLogs(testing.allocator, testing.io, .{
        .path = path,
        .follow = false,
        .tail = 3,
    }, &out, &err);

    try testing.expectEqualStrings("three\nfour\nfive\n", out.buffered());
}

test "runLogs: missing file emits the 'no log file yet' message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAbsLogPath(testing.allocator, tmp, "absent.log");
    defer testing.allocator.free(path);

    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try runLogs(testing.allocator, testing.io, .{
        .path = path,
        .follow = false,
    }, &out, &err);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "no log file yet") != null);
}

test "runLogs: tail=0 prints the entire file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempLog(tmp.dir, "g.log", "alpha\nbeta\n");
    const path = try tmpAbsLogPath(testing.allocator, tmp, "g.log");
    defer testing.allocator.free(path);

    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try runLogs(testing.allocator, testing.io, .{
        .path = path,
        .follow = false,
        .tail = 0,
    }, &out, &err);
    try testing.expectEqualStrings("alpha\nbeta\n", out.buffered());
}
