const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/root.zig");
const globals = @import("globals.zig");
const log_formatter = @import("gateway/log_formatter.zig");

/// Map the Zig build mode to our runtime `Profile`. `.bench` and
/// `.replay` are intentionally not derivable from the build mode —
/// they opt in via explicit flags (a future concern).
fn profileFromBuildMode() globals.Profile {
    return switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .release,
    };
}

/// Route all `std.log` calls through the gateway log formatter. The
/// formatter gates `.debug` on a runtime flag so `--verbose` can
/// flip debug on without recompilation.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_formatter.logFn,
};

pub fn main(init: std.process.Init) !u8 {
    // Set the process-wide build profile once, before any subsystem
    // boots. Downstream code reads it via globals.getProfile() when
    // decisions need to branch on debug-vs-release behavior.
    globals.setProfile(profileFromBuildMode());

    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stdout_w.interface.flush() catch {};
    defer stderr_w.interface.flush() catch {};

    if (argv.len < 2) {
        // Default (`tigerclaw` with no args) launches the in-process
        // TUI — no gateway daemon, no HTTP round-trip. The runner
        // lives inside the TUI's process and talks to the provider
        // directly.
        return runTuiLocal(arena, io, init);
    }

    // Convert [:0]const u8 slices to []const u8 for the parser.
    const tail = try arena.alloc([]const u8, argv.len - 1);
    for (argv[1..], 0..) |a, i| tail[i] = a;

    const cmd = cli.parse(tail) catch |err| switch (err) {
        error.MissingCommand => {
            try cli.printHelp(&stderr_w.interface);
            return 64;
        },
        error.CompletionMissingShell => {
            try stderr_w.interface.writeAll("tigerclaw: completion requires a shell (bash|zsh|fish)\n");
            return 64;
        },
        error.CompletionUnknownShell => {
            try stderr_w.interface.writeAll("tigerclaw: unknown completion shell; expected bash|zsh|fish\n");
            return 64;
        },
        error.UnknownFlag => {
            try stderr_w.interface.writeAll("tigerclaw: unknown flag\n");
            return 64;
        },
        error.MissingFlagValue => {
            try stderr_w.interface.writeAll("tigerclaw: flag requires a value\n");
            return 64;
        },
        error.ChannelsMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: channels requires a subcommand (list|status|telegram)\n");
            return 64;
        },
        error.ChannelsUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown channels subcommand\n");
            return 64;
        },
        error.ChannelsTelegramTestMissingFields => {
            try stderr_w.interface.writeAll("tigerclaw: channels telegram test requires --to and --text\n");
            return 64;
        },
        error.CassetteMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: cassette requires a subcommand (list|show|replay)\n");
            return 64;
        },
        error.CassetteUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown cassette subcommand\n");
            return 64;
        },
        error.CassetteMissingPath => {
            try stderr_w.interface.writeAll("tigerclaw: cassette show/replay requires a path\n");
            return 64;
        },
        error.TraceMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: trace requires a subcommand (list|show|diff)\n");
            return 64;
        },
        error.TraceUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown trace subcommand\n");
            return 64;
        },
        error.TraceMissingPath => {
            try stderr_w.interface.writeAll("tigerclaw: trace show requires a path; trace diff requires two paths\n");
            return 64;
        },
        error.ProvidersMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: providers requires a subcommand (list|status)\n");
            return 64;
        },
        error.ProvidersUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown providers subcommand\n");
            return 64;
        },
        error.ModelsMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: models requires a subcommand (list|status|set)\n");
            return 64;
        },
        error.ModelsUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown models subcommand\n");
            return 64;
        },
        error.ModelsMissingModel => {
            try stderr_w.interface.writeAll("tigerclaw: models set requires a <model> argument\n");
            return 64;
        },
        error.DiagMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: diag requires a subcommand (tail|show)\n");
            return 64;
        },
        error.DiagUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown diag subcommand\n");
            return 64;
        },
        error.DiagMissingEventId => {
            try stderr_w.interface.writeAll("tigerclaw: diag show requires an <event-id> argument\n");
            return 64;
        },
        error.DiagInvalidLineCount => {
            try stderr_w.interface.writeAll("tigerclaw: diag --lines requires a non-negative integer\n");
            return 64;
        },
        error.DebugMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: debug requires a subcommand (runner)\n");
            return 64;
        },
        error.DebugUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown debug subcommand\n");
            return 64;
        },
        error.DebugUnknownFlag => {
            try stderr_w.interface.writeAll("tigerclaw: unknown flag for debug subcommand\n");
            return 64;
        },
        error.DebugMissingFlagValue => {
            try stderr_w.interface.writeAll("tigerclaw: debug flag requires a value\n");
            return 64;
        },
        error.DebugMissingMessage => {
            try stderr_w.interface.writeAll("tigerclaw: debug runner requires --message\n");
            return 64;
        },
        error.GatewayLogsInvalidTailCount => {
            try stderr_w.interface.writeAll("tigerclaw: gateway logs --tail requires a non-negative integer\n");
            return 64;
        },
        error.GatewayInvalidPort => {
            try stderr_w.interface.writeAll("tigerclaw: gateway --port requires a valid 1-65535 integer\n");
            return 64;
        },
        error.AgentMissingName => {
            try stderr_w.interface.writeAll("tigerclaw: agent <name> [-m \"message\"]\n");
            return 64;
        },
        error.DoctorUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: doctor [invariants]\n");
            return 64;
        },
    };

    switch (cmd) {
        .version => try cli.printVersion(&stdout_w.interface),
        .help => try cli.printHelp(&stdout_w.interface),
        .doctor => |sub| switch (sub) {
            .summary => try runDoctor(arena, init.environ_map, &stdout_w.interface),
            .invariants => {
                const failed = try cli.commands.doctor.writeInvariantsReport(arena, &stdout_w.interface);
                if (failed > 0) return 1;
            },
        },
        .completion => |shell| try cli.commands.completion.write(
            &stdout_w.interface,
            shell,
            &cli.command_table,
        ),
        .agent => |args| {
            cli.commands.agent.installInterruptHandler();
            const opts: cli.commands.agent.Options = .{
                .base_url = args.base_url,
                .agent_name = args.agent_name,
                .message = args.message,
                .session_id = args.session_id,
                .bearer = args.bearer,
                .out = &stdout_w.interface,
            };
            cli.commands.agent.run(arena, io, opts) catch |err| switch (err) {
                error.Interrupted => return 130,
                error.GatewayDown => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway unreachable\n");
                    return 69; // EX_UNAVAILABLE
                },
                error.Unauthorized => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected credentials\n");
                    return 77; // EX_NOPERM
                },
                error.BadRequest => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected the request\n");
                    return 65; // EX_DATAERR
                },
                error.InternalError => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway internal error\n");
                    return 70; // EX_SOFTWARE
                },
                error.InvalidResponse => {
                    try stderr_w.interface.writeAll("tigerclaw: invalid gateway response\n");
                    return 70;
                },
                error.UrlTooLong => {
                    try stderr_w.interface.writeAll("tigerclaw: base_url + session id too long\n");
                    return 64;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        .channels => |sub| {
            cli.commands.channels.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.GatewayDown => return 1,
                error.Unauthorized => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected credentials\n");
                    return 77;
                },
                error.BadRequest => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected the request\n");
                    return 65;
                },
                error.InternalError => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway internal error\n");
                    return 70;
                },
                error.InvalidResponse => {
                    try stderr_w.interface.writeAll("tigerclaw: invalid gateway response\n");
                    return 70;
                },
                error.UrlTooLong, error.BodyTooLarge => {
                    try stderr_w.interface.writeAll("tigerclaw: request payload too large\n");
                    return 64;
                },
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .providers => |sub| {
            cli.commands.providers.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.UrlTooLong => {
                    try stderr_w.interface.writeAll("tigerclaw: provider base URL too long\n");
                    return 64;
                },
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .cassette => |sub| {
            cli.commands.cassette.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.DirNotFound, error.FileNotFound, error.InvalidCassette, error.ReadFailed => return 1,
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .trace => |sub| {
            cli.commands.trace.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.DirNotFound, error.FileNotFound, error.InvalidTrace, error.ReadFailed => return 1,
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .models => |sub| {
            cli.commands.models.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.NoSession, error.GatewayDoesNotSupport => return 1,
                error.GatewayDown => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway unreachable\n");
                    return 69;
                },
                error.Unauthorized => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected credentials\n");
                    return 77;
                },
                error.BadRequest => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected the request\n");
                    return 65;
                },
                error.InternalError => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway internal error\n");
                    return 70;
                },
                error.InvalidResponse => {
                    try stderr_w.interface.writeAll("tigerclaw: invalid gateway response\n");
                    return 70;
                },
                error.UrlTooLong, error.BodyTooLarge, error.NoSpaceLeft => {
                    try stderr_w.interface.writeAll("tigerclaw: request payload too large\n");
                    return 64;
                },
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .diag => |sub| {
            // Resolve $HOME → the default instance diagnostics file and
            // inject it as the path override. We do the path build in
            // main so the diag command itself stays a pure reader with
            // no environment coupling — which also makes it trivially
            // testable.
            var resolved = sub;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const home = init.environ_map.get("HOME") orelse "";
            const default_path = try std.fmt.bufPrint(
                &path_buf,
                "{s}/.tigerclaw/instances/default/sessions/default/diagnostics.jsonl",
                .{home},
            );
            switch (resolved) {
                .tail => |*a| {
                    if (a.path == null) a.path = default_path;
                },
                .show => |*a| {
                    if (a.path == null) a.path = default_path;
                },
            }
            cli.commands.diag.run(
                arena,
                io,
                resolved,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |e| switch (e) {
                error.NotFound, error.FileReadFailed => return 1,
                error.OutOfMemory, error.WriteFailed => return e,
            };
        },
        .debug => |sub| {
            const home = init.environ_map.get("HOME") orelse "";
            cli.commands.debug.run(
                arena,
                io,
                sub,
                home,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |e| {
                try stderr_w.interface.print("tigerclaw: debug failed: {s}\n", .{@errorName(e)});
                return 1;
            };
        },
        .gateway => |opts| {
            const home = init.environ_map.get("HOME") orelse "";
            var state_buf: [std.fs.max_path_bytes]u8 = undefined;
            const state_path = try std.fmt.bufPrint(&state_buf, "{s}/.tigerclaw/instances/default", .{home});

            // Resolve the current working directory so `<cwd>/.tigerclaw/`
            // can override the global `<home>/.tigerclaw/`. A failure to
            // resolve is non-fatal — we just lose the overlay.
            const workspace = std.process.currentPathAlloc(io, arena) catch "";

            const addr = std.Io.net.IpAddress.parse(opts.host, opts.port) catch {
                try stderr_w.interface.print("tigerclaw: invalid bind {s}:{d}\n", .{ opts.host, opts.port });
                return 64;
            };
            const want_color = shouldEnableColor(init.environ_map, opts.force_color);
            cli.commands.gateway.runGateway(arena, io, .{
                .address = addr,
                .state_dir_path = state_path,
                .home_path = home,
                .workspace_path = workspace,
                // v0.1.0 single-agent: every turn goes through `tiger`.
                // Per-request agent dispatch flips on with the runner
                // registry in v0.2.0.
                .agent_name = "tiger",
                .verbose = opts.verbose,
                .color = want_color,
                .host_str = opts.host,
                .force = opts.force,
            }, &stdout_w.interface, &stderr_w.interface) catch |e| {
                try stderr_w.interface.print("tigerclaw: gateway failed: {s}\n", .{@errorName(e)});
                return 1;
            };
        },
        .gateway_stop => |opts| {
            var state_buf: [std.fs.max_path_bytes]u8 = undefined;
            const home = init.environ_map.get("HOME") orelse "";
            const state_path = try std.fmt.bufPrint(
                &state_buf,
                "{s}/.tigerclaw/instances/default",
                .{home},
            );
            cli.commands.gateway.runStop(io, .{
                .state_dir_path = state_path,
                .force = opts.force,
                .host = opts.host,
                .port = opts.port,
                .allocator = arena,
            }, &stdout_w.interface) catch |e| switch (e) {
                error.NotRunning => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway is not running\n");
                    return 1;
                },
                error.OrphanListener => {
                    // Distinct exit code (3) so scripts can branch —
                    // this is recoverable with operator action but
                    // the stop itself did not succeed.
                    try stderr_w.interface.print(
                        "tigerclaw: a process is holding {s}:{d} but we can't identify it. " ++
                            "Check `lsof -iTCP:{d} -sTCP:LISTEN` and terminate it manually.\n",
                        .{ opts.host, opts.port, opts.port },
                    );
                    return 3;
                },
                error.Timeout => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway did not stop within 5s (SIGKILL sent)\n");
                    return 2;
                },
                error.PidfileCorrupt, error.SignalFailed, error.StateDirOpenFailed => {
                    try stderr_w.interface.print("tigerclaw: gateway stop failed: {s}\n", .{@errorName(e)});
                    return 1;
                },
                error.OutOfMemory, error.WriteFailed => return e,
            };
        },
        .gateway_logs => |opts| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const home = init.environ_map.get("HOME") orelse "";
            const path = try std.fmt.bufPrint(
                &path_buf,
                "{s}/.tigerclaw/instances/default/logs/server.log",
                .{home},
            );
            if (opts.follow) cli.commands.gateway.installInterruptHandler();
            const tail_n: u32 = if (opts.tail == 0) 200 else opts.tail;
            cli.commands.gateway.runLogs(arena, io, .{
                .path = path,
                .follow = opts.follow,
                .tail = tail_n,
            }, &stdout_w.interface, &stderr_w.interface) catch |e| switch (e) {
                error.Interrupted => return 130,
                error.FileReadFailed => return 1,
                error.OutOfMemory, error.WriteFailed => return e,
            };
        },
        .uninstall => |a| {
            // Resolve $HOME/.tigerclaw if the parser didn't get an
            // override (it never does from argv; this is the prod
            // path). Tests call run() directly with a tmpdir-backed
            // state_dir.
            var resolved = a;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (resolved.state_dir == null) {
                const home = init.environ_map.get("HOME") orelse "";
                resolved.state_dir = try std.fmt.bufPrint(
                    &path_buf,
                    "{s}/.tigerclaw",
                    .{home},
                );
            }

            var stdin_buf: [256]u8 = undefined;
            var stdin_r = std.Io.File.stdin().reader(io, &stdin_buf);

            cli.commands.uninstall.run(
                arena,
                io,
                resolved,
                &stdin_r.interface,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |e| switch (e) {
                error.Aborted => return 1,
                error.PermissionDenied => {
                    try stderr_w.interface.writeAll("tigerclaw: permission denied removing state directory\n");
                    return 77;
                },
                error.StateRemovalFailed => {
                    try stderr_w.interface.writeAll("tigerclaw: failed to remove state directory\n");
                    return 1;
                },
                error.PromptReadFailed => {
                    try stderr_w.interface.writeAll("tigerclaw: failed to read confirmation from stdin\n");
                    return 1;
                },
                error.OutOfMemory, error.WriteFailed => return e,
            };
        },
        .unknown => |flag| {
            try stderr_w.interface.print("tigerclaw: unknown option '{s}'\n\n", .{flag});
            try cli.printHelp(&stderr_w.interface);
            return 64;
        },
    }
    return 0;
}

/// Decide whether to emit ANSI colour. Honours `NO_COLOR` (any
/// non-empty value disables colour per the informal standard at
/// no-color.org) and the common `TERM=dumb` marker. On non-POSIX
/// targets we currently stay monochrome.
fn shouldEnableColor(env: *std.process.Environ.Map, force: bool) bool {
    if (force) return true;
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return false;
    // NO_COLOR wins over FORCE_COLOR per the informal standard.
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    // FORCE_COLOR=1 / any non-empty value opts in even without a TTY.
    // Useful when piping into pagers that do grok ANSI (e.g. `less -R`).
    if (env.get("FORCE_COLOR")) |v| if (v.len > 0) return true;
    if (env.get("TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    // Zig 0.16 dropped std.posix.isatty; use libc directly. stdout is
    // the banner sink, so we probe fd 1 rather than fd 2 here.
    return std.c.isatty(1) != 0;
}

fn runDoctor(
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    w: *std.Io.Writer,
) !void {
    try cli.commands.doctor.writeReport(arena, w, .{
        .zig_version = builtin.zig_version_string,
        .os_tag = @tagName(builtin.target.os.tag),
        .arch_tag = @tagName(builtin.target.cpu.arch),
        .profile = @tagName(globals.getProfile()),
        .env_config = environ_map.get("TIGERCLAW_CONFIG"),
        .env_xdg = environ_map.get("XDG_CONFIG_HOME"),
        .env_home = environ_map.get("HOME"),
    });
}

test {
    // Pull in tests from the library surface so `zig build test`
    // (rooted at main.zig) sees all of them.
    std.testing.refAllDecls(@import("root.zig"));
}

// ── shouldEnableColor tests ──────────────────────────────────
//
// Pure-function coverage for the env-driven color policy. We
// cannot assert the isatty-backed "no env, is TTY" branch here
// reliably — the test runner may or may not be attached to one —
// so these tests only cover the early-return paths.

fn makeEnvMap(
    allocator: std.mem.Allocator,
    entries: []const [2][]const u8,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    for (entries) |kv| try map.put(kv[0], kv[1]);
    return map;
}

test "shouldEnableColor: force=true always wins" {
    var map = try makeEnvMap(std.testing.allocator, &.{
        .{ "NO_COLOR", "1" },
        .{ "TERM", "dumb" },
    });
    defer map.deinit();
    try std.testing.expect(shouldEnableColor(&map, true));
}

test "shouldEnableColor: NO_COLOR disables even with FORCE_COLOR" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var map = try makeEnvMap(std.testing.allocator, &.{
        .{ "NO_COLOR", "1" },
        .{ "FORCE_COLOR", "1" },
    });
    defer map.deinit();
    try std.testing.expect(!shouldEnableColor(&map, false));
}

test "shouldEnableColor: empty NO_COLOR does not disable" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var map = try makeEnvMap(std.testing.allocator, &.{
        .{ "NO_COLOR", "" },
        .{ "FORCE_COLOR", "1" },
    });
    defer map.deinit();
    try std.testing.expect(shouldEnableColor(&map, false));
}

test "shouldEnableColor: FORCE_COLOR beats missing TTY" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var map = try makeEnvMap(std.testing.allocator, &.{
        .{ "FORCE_COLOR", "1" },
    });
    defer map.deinit();
    try std.testing.expect(shouldEnableColor(&map, false));
}

test "shouldEnableColor: TERM=dumb disables when nothing forces it" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var map = try makeEnvMap(std.testing.allocator, &.{
        .{ "TERM", "dumb" },
    });
    defer map.deinit();
    try std.testing.expect(!shouldEnableColor(&map, false));
}

test "shouldEnableColor: windows/wasi stay monochrome without force" {
    if (builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi) return error.SkipZigTest;
    var map = try makeEnvMap(std.testing.allocator, &.{});
    defer map.deinit();
    try std.testing.expect(!shouldEnableColor(&map, false));
}

const tui = @import("tui/root.zig");

fn runTuiLocal(arena: std.mem.Allocator, io: std.Io, init: std.process.Init) !u8 {
    const home = init.environ_map.get("HOME") orelse "";
    tui.run(arena, io, .{ .home = home }) catch |err| {
        // The tty is now in an undefined state if vaxis bailed
        // mid-render; print to stderr via libc write so we don't
        // re-enter the possibly-broken Io write path.
        const msg = std.fmt.allocPrint(arena, "tigerclaw tui: {s}\n", .{@errorName(err)}) catch "tui failed\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        return 1;
    };
    return 0;
}
