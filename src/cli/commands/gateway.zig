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
