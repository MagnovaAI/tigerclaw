//! `tigerclaw gateway` parser. CLI shape:
//!
//!   tigerclaw gateway [--port PORT] [--host HOST]
//!     Run the gateway daemon in the foreground. SIGTERM (or Ctrl-C)
//!     stops it cleanly through the documented drain ordering.
//!
//!   tigerclaw gateway logs [--follow] [--tail N]
//!     Read the daemon log file. Read-side helper — does NOT touch the
//!     running daemon.
//!
//! The CLI flattens "start the gateway" to bare `gateway`
//! with optional bind flags rather than a `start` sub-verb. We follow
//! that convention so muscle memory transfers; sub-verbs only exist
//! for read-side helpers that don't conflict with the run intent.

const std = @import("std");

pub const Verb = union(enum) {
    /// Bare `tigerclaw gateway` (or with --port/--host flags) — runs
    /// the daemon in the foreground.
    run: RunOptions,
    /// `tigerclaw gateway logs` — read the on-disk log file.
    logs: LogsOptions,
};

pub const RunOptions = struct {
    /// Bind host. Defaults to loopback; v0.1.0 has no auth so the bind
    /// stays loopback unless the operator opts in via flag.
    host: []const u8 = "127.0.0.1",
    /// Bind port. 8765 is the canonical local default the CLI verbs
    /// (agent, sessions, providers status, etc.) probe by default.
    port: u16 = 8765,
};

pub const LogsOptions = struct {
    /// When true, follow the log file (`tail -f` style).
    follow: bool = false,
    /// Number of trailing lines to print before (optionally) following.
    /// Zero means "all available".
    tail: u32 = 0,
};

pub const ParseError = error{
    UnknownSubVerb,
    UnknownFlag,
    MissingFlagValue,
    InvalidPort,
    InvalidTailCount,
};

pub fn parse(argv: []const []const u8) ParseError!Verb {
    // Bare `tigerclaw gateway` (no args) → run with defaults.
    if (argv.len == 0) return .{ .run = .{} };

    const first = argv[0];

    // `logs` is the only true sub-verb: its flag set differs from the
    // run options and a typo like `tigerclaw gateway logs --port 80`
    // should error rather than silently start a daemon.
    if (std.mem.eql(u8, first, "logs")) {
        return .{ .logs = try parseLogsOptions(argv[1..]) };
    }

    // Everything else is parsed as run options. A non-flag positional
    // is a clear typo — surface it before we silently bind to localhost.
    if (first.len == 0 or first[0] != '-') return error.UnknownSubVerb;

    return .{ .run = try parseRunOptions(argv) };
}

fn parseRunOptions(argv: []const []const u8) ParseError!RunOptions {
    var opts: RunOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "-p")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            const raw = argv[i + 1];
            opts.port = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--host")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            opts.host = argv[i + 1];
            i += 1;
            continue;
        }
        return error.UnknownFlag;
    }
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

// ---------------------------------------------------------------------------
// `gateway` execution — boot the daemon in the foreground.

const gateway_root = @import("../../gateway/root.zig");
const harness = @import("../../harness/root.zig");
const clock_mod = @import("../../clock.zig");
const tcp_server = @import("../../gateway/tcp_server.zig");
const live_runner = @import("live_runner.zig");
const agent_registry = @import("agent_registry.zig");

pub const RunRunOptions = struct {
    /// Resolved bind. Production main resolves --host into an IpAddress;
    /// tests inject a localhost ephemeral binding.
    address: std.Io.net.IpAddress,
    /// Caller-resolved absolute path to `<HOME>/.tigerclaw/state`. The
    /// boot layer owns subdirectory creation under it (outbox, etc.).
    state_dir_path: []const u8,
    /// Caller-resolved $HOME so the runner can find config.json + the
    /// agent's SOUL.md. When empty, the live runner falls back to
    /// MockAgentRunner so the daemon still boots in places without a
    /// home directory (CI, tmpdirs, etc.).
    home_path: []const u8 = "",
    /// Name of the agent the live runner uses for every turn in
    /// v0.1.0. Per-request agent dispatch lands when the runner gets
    /// promoted from a single-agent shim to a registry.
    agent_name: []const u8 = "tiger",
};

pub const RunRunError = error{
    StateDirOpenFailed,
    BindFailed,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

fn wallNowNs() i128 {
    // Zig 0.16 dropped std.time.nanoTimestamp; reach for the libc
    // clock_gettime directly. CLOCK.REALTIME mirrors the wall clock.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Boot the gateway in the foreground. Blocks until SIGTERM/SIGINT
/// trips `tcp_server.requestStop`, then runs the documented drain
/// (in-flight wait → manager stop → outbox flush) before returning.
/// The mock agent runner is wired in v0.1.0; the real react-loop
/// runner replaces it without changing this surface.
pub fn runGateway(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunRunOptions,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) RunRunError!void {
    var state_dir = std.Io.Dir.cwd().openDir(io, opts.state_dir_path, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            std.Io.Dir.cwd().createDirPath(io, opts.state_dir_path) catch return error.StateDirOpenFailed;
            break :blk std.Io.Dir.cwd().openDir(io, opts.state_dir_path, .{}) catch return error.StateDirOpenFailed;
        },
        else => return error.StateDirOpenFailed,
    };
    defer state_dir.close(io);

    // Reset the stop flag so consecutive runs in the same process
    // (tests, REPL-style smoke runs) do not inherit a poisoned flag.
    tcp_server.resetStopForTesting();

    var clock_cb: clock_mod.CallbackClock = .{ .now_fn = wallNowNs };
    var boot = gateway_root.boot.Boot.init(allocator, io, .{
        .address = opts.address,
        .state_root = state_dir,
        .routes = &gateway_root.routes.routes,
        .handlers = &gateway_root.routes.handlers,
        .clock = clock_cb.clock(),
    }) catch return error.BindFailed;
    defer boot.deinit();

    // Pre-load every agent under ~/.tigerclaw/agents. The route
    // handler routes turns by `req.session_id` (the CLI sets that to
    // the agent name) and falls back to a mock when no live runner
    // can be loaded so tests + bare boot still come up cleanly.
    var registry = agent_registry.AgentRegistry.init(allocator);
    defer registry.deinit();
    if (opts.home_path.len > 0) {
        registry.loadAll(io, opts.home_path) catch |e| {
            try err_w.print("tigerclaw: agent registry load warning: {s}\n", .{@errorName(e)});
        };
        try out.print("tigerclaw: loaded {d} live agent(s)\n", .{registry.entries.items.len});
        for (registry.entries.items) |e| {
            try out.print("  - {s} ({s} / {s})\n", .{
                e.name,
                @tagName(e.runner.provider_kind),
                e.runner.model,
            });
        }
    } else {
        try err_w.writeAll("tigerclaw: no HOME — falling back to mock runner\n");
    }
    var ctx: gateway_root.routes.Context = .{ .runner = registry.runner() };

    try out.print("tigerclaw gateway listening on {f}\n", .{opts.address});
    try out.flush();

    boot.run(&ctx) catch |e| {
        try err_w.print("tigerclaw: gateway exited with error: {s}\n", .{@errorName(e)});
        return;
    };

    try out.writeAll("tigerclaw gateway stopped cleanly\n");
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: bare gateway runs with default host + port" {
    const argv = [_][]const u8{};
    const v = try parse(&argv);
    try testing.expectEqualStrings("127.0.0.1", v.run.host);
    try testing.expectEqual(@as(u16, 8765), v.run.port);
}

test "parse: --port sets the bind port" {
    const argv = [_][]const u8{ "--port", "9000" };
    const v = try parse(&argv);
    try testing.expectEqual(@as(u16, 9000), v.run.port);
}

test "parse: -p short form for --port" {
    const argv = [_][]const u8{ "-p", "9001" };
    const v = try parse(&argv);
    try testing.expectEqual(@as(u16, 9001), v.run.port);
}

test "parse: --host sets the bind host" {
    const argv = [_][]const u8{ "--host", "0.0.0.0" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("0.0.0.0", v.run.host);
}

test "parse: --port with a non-integer returns InvalidPort" {
    const argv = [_][]const u8{ "--port", "lots" };
    try testing.expectError(error.InvalidPort, parse(&argv));
}

test "parse: --port without a value returns MissingFlagValue" {
    const argv = [_][]const u8{"--port"};
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "parse: bogus positional returns UnknownSubVerb" {
    const argv = [_][]const u8{"launch"};
    try testing.expectError(error.UnknownSubVerb, parse(&argv));
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
