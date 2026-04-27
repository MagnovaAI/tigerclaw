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
//! "Start the gateway" is the bare `gateway` invocation with
//! optional bind flags rather than a `start` sub-verb; sub-verbs
//! only exist for read-side helpers that don't conflict with the
//! run intent.

const std = @import("std");

pub const Verb = union(enum) {
    /// Bare `tigerclaw gateway` (or with --port/--host flags) — runs
    /// the daemon in the foreground.
    run: RunOptions,
    /// `tigerclaw gateway logs` — read the on-disk log file.
    logs: LogsOptions,
    /// `tigerclaw gateway stop [--force]` — signal the running daemon
    /// via its pidfile and wait for it to exit. `--force` skips the
    /// grace period and SIGKILLs.
    stop: StopOptions,
};

pub const RunOptions = struct {
    /// Bind host. Defaults to loopback; v0.1.0 has no auth so the bind
    /// stays loopback unless the operator opts in via flag.
    host: []const u8 = "127.0.0.1",
    /// Bind port. 8765 is the canonical local default the CLI verbs
    /// (agent, sessions, providers status, etc.) probe by default.
    port: u16 = 8765,
    /// Enable verbose/debug logging for gateway operations.
    verbose: bool = false,
    /// Force-enable ANSI colour even when stdout is not a TTY.
    /// Equivalent to `FORCE_COLOR=1`.
    force_color: bool = false,
    /// Kill any gateway already running from the pidfile before
    /// starting. Lets `tigerclaw gateway --force` act as a restart.
    force: bool = false,
};

pub const LogsOptions = struct {
    /// When true, follow the log file (`tail -f` style).
    follow: bool = false,
    /// Number of trailing lines to print before (optionally) following.
    /// Zero means "all available".
    tail: u32 = 0,
};

pub const StopOptions = struct {
    /// Always force-kill. The graceful drain path flaked on
    /// Ctrl-Z'd daemons and nobody wanted it in practice.
    force: bool = true,
    /// Port to probe when the pidfile is missing or stale. If a
    /// listener answers on this port we surface an orphan-listener
    /// error instead of the misleading "gateway is not running".
    /// Matches the daemon's default (`RunOptions.port`).
    port: u16 = 8765,
    /// Host to probe alongside `port`. Loopback by default; override
    /// only if the daemon was started against a non-default bind.
    host: []const u8 = "127.0.0.1",
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

    if (std.mem.eql(u8, first, "stop")) {
        return .{ .stop = try parseStopOptions(argv[1..]) };
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
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            opts.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--color")) {
            opts.force_color = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            opts.force = true;
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

fn parseStopOptions(argv: []const []const u8) ParseError!StopOptions {
    var opts: StopOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-9")) {
            // Retained as a no-op so existing scripts don't error.
            // Stop is always forceful now.
            continue;
        }
        if (std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "-p")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            opts.port = std.fmt.parseInt(u16, argv[i + 1], 10) catch return error.InvalidPort;
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
    /// `$HOME/.tigerclaw/instances/default/logs/server.log`; tests pass a tmpdir path.
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
const clock_mod = @import("clock");
const http_client = @import("http_client.zig");
const tcp_server = @import("../../gateway/tcp_server.zig");
const live_runner = @import("live_runner.zig");
const agent_registry = @import("agent_registry.zig");
const agents_loader = @import("agents_loader.zig");
const harness_agent_registry = @import("../../harness/agent_registry.zig");
const startup_log = @import("../../gateway/startup_log.zig");
const log_formatter = @import("../../gateway/log_formatter.zig");
const pidfile = @import("../../daemon/pidfile.zig");
const logfile = @import("../../daemon/logfile.zig");
const telemetry_mod = @import("../../telemetry.zig");

/// Pidfile name inside the instance directory. Kept as a stable
/// relative path so both start and stop paths agree.
pub const pidfile_name = "locks/daemon.pid";

const gw_log = std.log.scoped(.gateway);

pub const RunRunOptions = struct {
    /// Resolved bind. Production main resolves --host into an IpAddress;
    /// tests inject a localhost ephemeral binding.
    address: std.Io.net.IpAddress,
    /// Caller-resolved absolute path to
    /// `<HOME>/.tigerclaw/instances/default`. The boot layer owns
    /// subdirectory creation under it (outbox, etc.).
    state_dir_path: []const u8,
    /// Caller-resolved $HOME so the runner can find config.json + the
    /// agent's SOUL.md. When empty, the live runner falls back to
    /// MockAgentRunner so the daemon still boots in places without a
    /// home directory (CI, tmpdirs, etc.).
    home_path: []const u8 = "",
    /// Per-project override root. Resolved by main as the current
    /// working directory; if `<workspace>/.tigerclaw/` exists its
    /// agents override `<home>/.tigerclaw/agents/` by name. Empty
    /// means "no workspace overlay" (the old global-only behaviour).
    workspace_path: []const u8 = "",
    /// Name of the agent the live runner uses for every turn in
    /// v0.1.0. Per-request agent dispatch lands when the runner gets
    /// promoted from a single-agent shim to a registry.
    agent_name: []const u8 = "tiger",
    /// Enable verbose/debug logging.
    verbose: bool = false,
    /// Enable ANSI colour in the banner and log lines. Caller
    /// decides based on NO_COLOR / isatty / --color flags.
    color: bool = false,
    /// Pre-formatted host string for the banner (the IpAddress
    /// union doesn't expose a cheap to_string in Zig 0.16).
    host_str: []const u8 = "127.0.0.1",
    /// If true, stop any daemon referenced by the pidfile before
    /// binding — enables `tigerclaw gateway --force` restart UX.
    force: bool = false,
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

fn ensureInstanceSkeleton(io: std.Io, state_dir: std.Io.Dir) RunRunError!void {
    const dirs = [_][]const u8{
        "sessions",
        "audit",
        "meter",
        "telemetry",
        "inbox",
        "outbox",
        "locks",
        "logs",
    };
    for (dirs) |dir| {
        state_dir.createDirPath(io, dir) catch return error.StateDirOpenFailed;
    }
}

fn appendGatewayLog(ptr: *anyopaque, line: []const u8) void {
    const sink: *logfile.LogSink = @ptrCast(@alignCast(ptr));
    sink.append(line) catch {};
}

fn logResourceSample(label: []const u8) void {
    const sample = telemetry_mod.sampleResources();
    gw_log.info(
        "[RAM:{d}MiB,CPU:{d}.{d:0>2}%] metric phase={s} app_cpu_used_us={d} app_cpu_percent_x100={d} app_cpu_available_cores={d} cpu_user_us={d} cpu_system_us={d} app_ram_used_bytes={d} app_ram_available_bytes={d} system_ram_total_bytes={d} app_ram_used_pct_x100={d} app_ram_peak_bytes={d}",
        .{
            sample.app_ram_used_bytes / std.math.pow(u64, 1024, 2),
            sample.cpu_percent_x100 / 100,
            sample.cpu_percent_x100 % 100,
            label,
            sample.cpu_total_us,
            sample.cpu_percent_x100,
            sample.cpu_logical_cores,
            sample.cpu_user_us,
            sample.cpu_system_us,
            sample.app_ram_used_bytes,
            sample.appRamAvailableBytes(),
            sample.system_ram_total_bytes,
            sample.appRamUsedPctX100(),
            sample.max_rss_bytes,
        },
    );
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
    _ = err_w;
    // Wire runtime log state. `--verbose` bumps the logFn gate to
    // emit `.debug`; colour is off unless the caller explicitly
    // opted in via NO_COLOR / isatty logic at the main.zig layer.
    log_formatter.setVerbose(opts.verbose);
    log_formatter.setColor(opts.color);

    const build_options = @import("build_options");
    startup_log.printBanner(out, .{
        .version = build_options.version,
        .commit = build_options.commit,
        .host = opts.host_str,
        .port = opts.address.getPort(),
        .verbose = opts.verbose,
        .color = opts.color,
    });
    out.flush() catch {};

    gw_log.info("loading configuration...", .{});
    gw_log.debug("state root requested: {s}", .{opts.state_dir_path});
    logResourceSample("gateway_start");

    var state_dir = std.Io.Dir.cwd().openDir(io, opts.state_dir_path, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            std.Io.Dir.cwd().createDirPath(io, opts.state_dir_path) catch return error.StateDirOpenFailed;
            break :blk std.Io.Dir.cwd().openDir(io, opts.state_dir_path, .{}) catch return error.StateDirOpenFailed;
        },
        else => return error.StateDirOpenFailed,
    };
    defer state_dir.close(io);
    gw_log.info("state root ready: {s}", .{opts.state_dir_path});

    try ensureInstanceSkeleton(io, state_dir);
    gw_log.info("runtime directories ready", .{});

    var log_sink = logfile.LogSink.open(io, state_dir, "logs/server.log") catch null;
    defer if (log_sink) |*sink| sink.close();
    if (log_sink) |*sink| {
        log_formatter.setFileSink(.{ .ptr = sink, .append = appendGatewayLog });
    }
    defer log_formatter.setFileSink(null);
    gw_log.info("log file: {s}/logs/server.log", .{opts.state_dir_path});
    logResourceSample("log_sink_ready");

    // `--force` is a restart operation. Kill any live daemon hard,
    // clear stale bookkeeping, and evict an orphan listener before
    // this process writes its own pidfile. Using SIGKILL here avoids
    // the old daemon's defer path racing us and deleting the new
    // pidfile after we publish it.
    if (opts.force) {
        forceClearExistingGateway(allocator, io, state_dir, opts.host_str, opts.address.getPort()) catch {
            return error.BindFailed;
        };
    }

    // Publish our pid so `gateway stop` can find us. Stale pidfiles
    // from a previously-crashed daemon are overwritten unconditionally —
    // `isStale` would just tell us the process is gone, same result.
    const self_pid: pidfile.Pid = @intCast(std.c.getpid());
    pidfile.write(io, state_dir, pidfile_name, self_pid) catch |e| {
        gw_log.warn("pidfile write failed: {s}", .{@errorName(e)});
    };
    defer pidfile.remove(io, state_dir, pidfile_name) catch {};
    gw_log.info("pidfile ready: {s} pid={d}", .{ pidfile_name, self_pid });

    // Reset the stop flag so consecutive runs in the same process
    // (tests, REPL-style smoke runs) do not inherit a poisoned flag.
    tcp_server.resetStopForTesting();
    gw_log.info("shutdown handlers armed", .{});

    var clock_cb: clock_mod.CallbackClock = .{ .now_fn = wallNowNs };
    gw_log.info("resolving agents...", .{});

    // Load the AgentsConfig from disk and convert to a harness
    // Registry for Boot.init to walk. An empty or missing agents
    // directory is not fatal — we proceed without live channels and
    // the daemon still answers HTTP routes.
    var loaded_agents_opt: ?agents_loader.Loaded = null;
    var harness_registry_opt: ?harness_agent_registry.Registry = null;
    defer if (loaded_agents_opt) |*l| l.deinit();
    defer if (harness_registry_opt) |*r| r.deinit();
    if (opts.home_path.len > 0 or opts.workspace_path.len > 0) {
        if (agents_loader.load(allocator, io, opts.workspace_path, opts.home_path)) |loaded| {
            loaded_agents_opt = loaded;
            // Demoted to debug: the banner below already reports the
            // loaded agents + default. Surfacing these as info pushed
            // them above the banner in stderr / stdout interleaving.
            gw_log.debug("agents loader: {d} agents loaded, default={s}", .{
                loaded.config.entries.len,
                loaded.config.default,
            });
            if (harness_agent_registry.build(allocator, loaded.config)) |built| {
                harness_registry_opt = built;
                gw_log.debug("agents registry built with {d} entries", .{built.entries.len});
            } else |err| {
                gw_log.warn("agents registry build failed: {s}", .{@errorName(err)});
            }
        } else |err| {
            gw_log.warn("agents loader failed: {s}", .{@errorName(err)});
        }
    } else {
        gw_log.warn("home_path is empty — no agents loaded", .{});
    }
    logResourceSample("agents_resolved");

    gw_log.info("initializing gateway runtime...", .{});
    var boot = gateway_root.boot.Boot.init(allocator, io, .{
        .address = opts.address,
        .state_root = state_dir,
        .state_root_path = opts.state_dir_path,
        .routes = &gateway_root.routes.routes,
        .handlers = &gateway_root.routes.handlers,
        .clock = clock_cb.clock(),
        .agents = if (harness_registry_opt) |*r| r else null,
        .startup_log = out,
    }) catch |boot_err| {
        gw_log.warn("Boot.init failed: {s}", .{@errorName(boot_err)});
        return error.BindFailed;
    };
    defer boot.deinit();
    gw_log.info("gateway runtime initialized", .{});
    logResourceSample("runtime_initialized");

    // Pre-load every agent under ~/.tigerclaw/agents. Registry
    // load happens before the banner so the banner can show the
    // final agent list; we therefore hold any per-agent debug
    // output until after the banner prints (see below).
    var registry = agent_registry.AgentRegistry.init(allocator);
    defer registry.deinit();
    var load_err: ?anyerror = null;
    if (opts.home_path.len > 0 or opts.workspace_path.len > 0) {
        gw_log.info("loading runtime agents...", .{});
        registry.loadAll(io, opts.workspace_path, opts.home_path) catch |e| {
            load_err = e;
        };
        gw_log.info("runtime agents loaded: {d}", .{registry.entries.items.len});
    }
    var ctx: gateway_root.routes.Context = .{
        .runner = registry.runner(),
        .db = &boot.db,
        .clock = clock_cb.clock(),
        .io = io,
    };

    // Build the agent-name list for the banner without allocating
    // in the banner path. The registry owns these slices for the
    // duration of this function. Capped at 32 entries to keep the
    // stack buffer tiny; we warn once if a deployment exceeds that.
    var agent_names_buf: [32][]const u8 = undefined;
    var agent_names_len: usize = 0;
    for (registry.entries.items) |e| {
        if (agent_names_len == agent_names_buf.len) break;
        agent_names_buf[agent_names_len] = e.name;
        agent_names_len += 1;
    }
    const agent_truncated = registry.entries.items.len > agent_names_buf.len;

    // Pick a representative "agent model" for the banner line —
    // the first entry's provider/model. When no agents are loaded
    // the line is omitted entirely.
    // Lifetime: `model_buf` is a stack var in runGateway and the
    // `?[]const u8` slice below aliases it. That is safe because
    // `printBanner` returns synchronously before this frame unwinds.
    var model_buf: [128]u8 = undefined;
    const agent_model: ?[]const u8 = if (registry.entries.items.len > 0) blk: {
        const e = registry.entries.items[0];
        break :blk std.fmt.bufPrint(&model_buf, "{s}/{s}", .{
            @tagName(e.runner.provider_kind),
            e.runner.model,
        }) catch null;
    } else null;

    if (agent_model) |model| {
        gw_log.info("agent model: {s}", .{model});
    }
    gw_log.info("ready ({d} agents loaded)", .{agent_names_len});
    logResourceSample("banner_printed");

    // Post-banner diagnostics. Warnings surface regardless of
    // verbose; the per-agent dump only fires under `--verbose`
    // because the banner already lists agent names.
    if (load_err) |e| {
        gw_log.warn("agent registry load warning: {s}", .{@errorName(e)});
    }
    if (agent_truncated) {
        gw_log.warn(
            "banner agent list truncated: {d} of {d} agents shown",
            .{ agent_names_buf.len, registry.entries.items.len },
        );
    }
    if (opts.home_path.len == 0) {
        gw_log.debug("no HOME — falling back to mock runner", .{});
    }
    for (registry.entries.items) |e| {
        gw_log.debug("agent {s} ({s}/{s})", .{
            e.name,
            @tagName(e.runner.provider_kind),
            e.runner.model,
        });
    }

    gw_log.info("starting HTTP server on {s}:{d}", .{ opts.host_str, opts.address.getPort() });
    boot.run(&ctx) catch |e| {
        gw_log.err("gateway exited with error: {s}", .{@errorName(e)});
        return;
    };

    logResourceSample("gateway_stopped");
    gw_log.info("gateway stopped cleanly", .{});
    try out.writeAll("tigerclaw gateway stopped cleanly\n");
}

const ForceClearError = error{GatewayStillRunning};

fn forceClearExistingGateway(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: std.Io.Dir,
    host: []const u8,
    port: u16,
) ForceClearError!void {
    if (pidfile.read(io, state_dir, pidfile_name)) |existing_pid| {
        if (pidfile.isStale(io, state_dir, pidfile_name)) {
            pidfile.remove(io, state_dir, pidfile_name) catch {};
            gw_log.info("--force: cleared stale pidfile pid={d}", .{existing_pid});
        } else {
            gw_log.info("--force: killing existing gateway pid={d}", .{existing_pid});
            killAndWait(io, existing_pid, host, port) catch return error.GatewayStillRunning;
            pidfile.remove(io, state_dir, pidfile_name) catch {};
        }
    } else |err| switch (err) {
        error.FileMissing => {},
        error.Corrupt, error.IoFailure => {
            pidfile.remove(io, state_dir, pidfile_name) catch {};
            gw_log.warn("--force: removed unreadable pidfile: {s}", .{@errorName(err)});
        },
    }

    if (!probeGatewayPort(allocator, io, host, port)) return;

    const orphan_pid = findOrphanPid(allocator, port) orelse {
        gw_log.warn("--force: {s}:{d} is still occupied but no listener pid was found", .{ host, port });
        return error.GatewayStillRunning;
    };
    gw_log.info("--force: killing orphan gateway listener pid={d} port={d}", .{ orphan_pid, port });
    killAndWait(io, orphan_pid, host, port) catch return error.GatewayStillRunning;
}

fn killAndWait(
    io: std.Io,
    pid: std.posix.pid_t,
    host: []const u8,
    port: u16,
) ForceClearError!void {
    std.posix.kill(pid, std.posix.SIG.CONT) catch {};
    std.posix.kill(pid, std.posix.SIG.KILL) catch |e| switch (e) {
        error.ProcessNotFound => return,
        else => return error.GatewayStillRunning,
    };

    const poll_ns: u64 = 100 * std.time.ns_per_ms;
    const max_ns: u64 = 5 * std.time.ns_per_s;
    var waited: u64 = 0;
    while (waited < max_ns) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(poll_ns), .awake) catch {};
        waited += poll_ns;

        const pid_gone = blk: {
            std.posix.kill(pid, @enumFromInt(0)) catch |e| switch (e) {
                error.ProcessNotFound => break :blk true,
                else => break :blk false,
            };
            break :blk false;
        };
        if (pid_gone or !probeGatewayPort(std.heap.page_allocator, io, host, port)) {
            return;
        }
    }
    return error.GatewayStillRunning;
}

// ---------------------------------------------------------------------------
// `gateway stop` execution — signal the running daemon via its pidfile.

pub const StopRunOptions = struct {
    /// Caller-resolved absolute path to `<HOME>/.tigerclaw/instances/default`.
    state_dir_path: []const u8,
    force: bool = false,
    /// Host + port probed when the pidfile is missing or stale. A
    /// live listener on this port while bookkeeping says "not
    /// running" is an orphan — we surface that as its own error so
    /// the CLI can tell the operator to investigate.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8765,
    /// Allocator used by the port probe's HTTP client. The probe
    /// lives for the duration of a single `runStop` call, so any
    /// general-purpose allocator is fine.
    allocator: std.mem.Allocator,
};

pub const StopRunError = error{
    NotRunning,
    /// Pidfile says "not running" but `host:port` has a live
    /// listener. Operator intervention required — most commonly a
    /// crashed daemon that never cleaned its pidfile, or a stray
    /// process occupying the port under a different identity.
    OrphanListener,
    PidfileCorrupt,
    SignalFailed,
    StateDirOpenFailed,
    Timeout,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Signal the daemon referenced by `<instance_dir>/locks/daemon.pid` and wait
/// for it to clear. SIGTERM is the default; `--force` sends SIGKILL
/// immediately. A soft 5s grace period gives the drain path time to
/// finish; on timeout we escalate to SIGKILL automatically.
pub fn runStop(
    io: std.Io,
    opts: StopRunOptions,
    out: *std.Io.Writer,
) StopRunError!void {
    var state_dir = std.Io.Dir.cwd().openDir(io, opts.state_dir_path, .{}) catch {
        return error.StateDirOpenFailed;
    };
    defer state_dir.close(io);

    const pid = pidfile.read(io, state_dir, pidfile_name) catch |e| switch (e) {
        // Pidfile is gone — but something may still be bound to the
        // gateway port. Probe before trusting the bookkeeping; an
        // orphan listener needs operator attention, not a bland
        // "not running" message.
        error.FileMissing => {
            if (probeGatewayPort(opts.allocator, io, opts.host, opts.port)) {
                // Try to identify and kill the orphan via `lsof -ti`.
                // Shelling out is ugly but beats the alternative of
                // linking against libproc or asking the operator to
                // run lsof themselves every time. Only fires when
                // --force is set so casual `gateway stop` calls still
                // require a conscious confirmation from the operator.
                if (opts.force) {
                    if (findOrphanPid(opts.allocator, opts.port)) |orphan_pid| {
                        std.posix.kill(orphan_pid, std.posix.SIG.CONT) catch {};
                        std.posix.kill(orphan_pid, std.posix.SIG.KILL) catch {};
                        try out.print(
                            "gateway orphan (pid {d}) on {s}:{d} killed\n",
                            .{ orphan_pid, opts.host, opts.port },
                        );
                        return;
                    }
                }
                try out.print(
                    "pidfile missing but {s}:{d} has a live listener — orphan process holding the port; pass --force to kill it\n",
                    .{ opts.host, opts.port },
                );
                return error.OrphanListener;
            }
            return error.NotRunning;
        },
        error.Corrupt => return error.PidfileCorrupt,
        error.IoFailure => return error.StateDirOpenFailed,
    };

    // If the pid is already dead, skip the signal dance and just
    // clean up the stale pidfile so the next start is quiet. But
    // probe the port first — if the pidfile's pid is dead yet the
    // port is still held, a different process has taken over and
    // the operator needs to know.
    if (pidfile.isStale(io, state_dir, pidfile_name)) {
        pidfile.remove(io, state_dir, pidfile_name) catch {};
        if (probeGatewayPort(opts.allocator, io, opts.host, opts.port)) {
            try out.print(
                "gateway pid {d} is dead but {s}:{d} has a live listener — orphan process holding the port\n",
                .{ pid, opts.host, opts.port },
            );
            return error.OrphanListener;
        }
        try out.print("gateway pid {d} is not running (stale pidfile cleared)\n", .{pid});
        return error.NotRunning;
    }

    // Wake any suspended (Ctrl-Z'd, SIGSTOP'd) process before
    // signalling: a stopped process can only receive SIGKILL and
    // SIGCONT, so SIGTERM would be queued but never delivered,
    // leading to a five-second wait followed by a forced SIGKILL.
    // Sending SIGCONT to a non-stopped process is a no-op; swallow
    // any error from a race where the pid just exited.
    std.posix.kill(pid, std.posix.SIG.CONT) catch {};

    const first_sig = if (opts.force)
        std.posix.SIG.KILL
    else
        std.posix.SIG.TERM;

    std.posix.kill(pid, first_sig) catch |e| switch (e) {
        error.ProcessNotFound => {
            pidfile.remove(io, state_dir, pidfile_name) catch {};
            try out.print("gateway pid {d} already gone\n", .{pid});
            return;
        },
        else => return error.SignalFailed,
    };

    try out.print("signalled gateway (pid {d}) with {s}\n", .{
        pid,
        if (opts.force) "SIGKILL" else "SIGTERM",
    });

    // Poll at 100ms up to 5s. `kill(pid, 0)` is the probe — a
    // ProcessNotFound means the daemon unwound cleanly.
    const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;
    const max_wait_ns: u64 = 5 * std.time.ns_per_s;
    var waited_ns: u64 = 0;
    while (waited_ns < max_wait_ns) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(poll_interval_ns), .awake) catch {};
        waited_ns += poll_interval_ns;
        std.posix.kill(pid, @enumFromInt(0)) catch |e| switch (e) {
            error.ProcessNotFound => {
                pidfile.remove(io, state_dir, pidfile_name) catch {};
                try out.print("gateway exited cleanly\n", .{});
                return;
            },
            else => break,
        };
    }

    // Grace period elapsed. Escalate to SIGKILL unless we already
    // sent one; either way surface a Timeout so shell scripts can
    // decide whether to retry.
    if (!opts.force) {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        try out.print("gateway did not exit in 5s — sent SIGKILL\n", .{});
    }
    pidfile.remove(io, state_dir, pidfile_name) catch {};
    return error.Timeout;
}

// libc declarations for orphan-pid discovery. Zig 0.16's
// `std.process.Child` API is in transition and doesn't yet expose a
// stable spawn-and-read pipeline, so we shell out via `popen(3)` and
// parse the first line of lsof output ourselves.
const LIBC_FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*LIBC_FILE;
extern "c" fn pclose(stream: *LIBC_FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, stream: *LIBC_FILE) usize;

/// Ask `lsof` who's listening on `port`. Returns the first matching
/// pid, or null if nothing is listening or lsof isn't installed. Only
/// used on the orphan-recovery path; the normal stop flow walks the
/// pidfile.
fn findOrphanPid(allocator: std.mem.Allocator, port: u16) ?std.posix.pid_t {
    _ = allocator;
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(
        &cmd_buf,
        "lsof -ti TCP:{d} -sTCP:LISTEN 2>/dev/null",
        .{port},
    ) catch return null;

    const f = popen(cmd.ptr, "r") orelse return null;
    defer _ = pclose(f);

    var out_buf: [64]u8 = undefined;
    const n = fread(&out_buf, 1, out_buf.len, f);
    if (n == 0) return null;

    const trimmed = std.mem.trim(u8, out_buf[0..n], " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    const first = it.next() orelse return null;
    const pid = std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, first, " \t\r"),
        10,
    ) catch return null;
    return pid;
}

/// Return `true` when `host:port` has anything accepting TCP. We use
/// a raw `connect(2)` with a short timeout rather than an HTTP GET —
/// a suspended (SIGSTOP'd) daemon leaves the kernel accept queue
/// functional, so `connect` succeeds, but it never answers `recv`,
/// which would hang an HTTP probe indefinitely. Connecting alone
/// answers the "is anything bound?" question in milliseconds.
fn probeGatewayPort(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
) bool {
    return probeGatewayPortWith(allocator, io, host, port, undefined, connectGatewayPort);
}

const ConnectFn = *const fn (
    io: std.Io,
    address: std.Io.net.IpAddress,
    ctx: *anyopaque,
) bool;

fn probeGatewayPortWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    ctx: *anyopaque,
    connect_fn: ConnectFn,
) bool {
    _ = allocator;
    const address = std.Io.net.IpAddress.parse(host, port) catch return false;
    return connect_fn(io, address, ctx);
}

fn connectGatewayPort(
    io: std.Io,
    address: std.Io.net.IpAddress,
    _: *anyopaque,
) bool {
    // No explicit timeout: Zig 0.16's posix Io has not implemented
    // netConnectIpPosix with a timeout, and this probe targets localhost
    // where the kernel returns ECONNREFUSED immediately if the port is
    // unbound. A hanging connect is not a concern here.
    const stream = address.connect(io, .{
        .mode = .stream,
    }) catch return false;
    // Immediately close — we only cared whether the three-way
    // handshake completed. Nothing to read or write.
    var s = stream;
    s.close(io);
    return true;
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

test "parse: stop is always force-kill" {
    const argv = [_][]const u8{"stop"};
    const v = try parse(&argv);
    try testing.expect(v.stop.force);
    try testing.expectEqualStrings("127.0.0.1", v.stop.host);
    try testing.expectEqual(@as(u16, 8765), v.stop.port);
}

test "parse: stop --force is accepted as a no-op for script compatibility" {
    const argv = [_][]const u8{ "stop", "--force", "--port", "9100", "--host", "0.0.0.0" };
    const v = try parse(&argv);
    try testing.expect(v.stop.force);
    try testing.expectEqual(@as(u16, 9100), v.stop.port);
    try testing.expectEqualStrings("0.0.0.0", v.stop.host);
}

test "parse: stop --port with a non-integer returns InvalidPort" {
    const argv = [_][]const u8{ "stop", "--port", "abc" };
    try testing.expectError(error.InvalidPort, parse(&argv));
}

test "probeGatewayPort: closed port returns false" {
    const FakeConnector = struct {
        fn connect(_: std.Io, _: @TypeOf(std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable), _: *anyopaque) bool {
            return false;
        }
    };

    try testing.expect(!probeGatewayPortWith(
        testing.allocator,
        testing.io,
        "127.0.0.1",
        8765,
        undefined,
        FakeConnector.connect,
    ));
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
