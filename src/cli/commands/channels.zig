//! `tigerclaw channels` — list, inspect, and probe configured channels.
//!
//! v0.1.0 surface is plumbing-only: list/status print canonical
//! placeholder rows, enable/disable acknowledge the request without
//! touching config (config writeback lands with the channel manager
//! commit), and `test` fires a POST against the local gateway to
//! prove the dispatch path is reachable.

const std = @import("std");
const http_client = @import("http_client.zig");

pub const Subcommand = union(enum) {
    list,
    status,
    telegram_enable,
    telegram_disable,
    telegram_test: TelegramTestArgs,
};

pub const TelegramTestArgs = struct {
    to: []const u8,
    text: []const u8,
    /// Optional agent to route the test message through. When set, the
    /// gateway picks the (agent, telegram) binding registered via
    /// `Manager.add`. When null, the gateway falls back to the default
    /// agent — matches prior behavior for single-agent deployments.
    agent: ?[]const u8 = null,
    base_url: []const u8 = "http://127.0.0.1:8765",
    bearer: ?[]const u8 = null,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
    /// `telegram test` requires --to and --text.
    TelegramTestMissingFields,
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    const first = argv[0];
    if (std.mem.eql(u8, first, "list")) return .list;
    if (std.mem.eql(u8, first, "status")) return .status;
    if (std.mem.eql(u8, first, "telegram")) {
        if (argv.len < 2) return error.MissingSubcommand;
        const second = argv[1];
        if (std.mem.eql(u8, second, "enable")) return .telegram_enable;
        if (std.mem.eql(u8, second, "disable")) return .telegram_disable;
        if (std.mem.eql(u8, second, "test")) return parseTest(argv[2..]);
        return error.UnknownSubcommand;
    }
    return error.UnknownSubcommand;
}

fn parseTest(rest: []const []const u8) ParseError!Subcommand {
    var args: TelegramTestArgs = .{ .to = "", .text = "" };
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--to")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.to = rest[i];
        } else if (std.mem.eql(u8, flag, "--text")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.text = rest[i];
        } else if (std.mem.eql(u8, flag, "--base-url")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.base_url = rest[i];
        } else if (std.mem.eql(u8, flag, "--bearer")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.bearer = rest[i];
        } else if (std.mem.eql(u8, flag, "--agent")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.agent = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }
    if (args.to.len == 0 or args.text.len == 0) return error.TelegramTestMissingFields;
    return .{ .telegram_test = args };
}

pub const Error = error{
    UrlTooLong,
    BodyTooLarge,
} || http_client.Error || std.Io.Writer.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    switch (cmd) {
        .list => {
            try out.writeAll("CHANNEL    STATE\n");
            try out.writeAll("telegram   disabled\n");
        },
        .status => {
            try out.writeAll("CHANNEL    RUNTIME\n");
            try out.writeAll("telegram   not running\n");
        },
        .telegram_enable => try out.writeAll("telegram channel enabled\n"),
        .telegram_disable => try out.writeAll("telegram channel disabled\n"),
        .telegram_test => |args| try runTelegramTest(allocator, io, args, out, err),
    }
}

fn runTelegramTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: TelegramTestArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/mock-session/messages",
        .{args.base_url},
    ) catch return error.UrlTooLong;

    var body_buf: [4096]u8 = undefined;
    const body = if (args.agent) |agent_name|
        std.fmt.bufPrint(
            &body_buf,
            "{{\"channel\":\"telegram\",\"agent\":\"{s}\",\"to\":\"{s}\",\"text\":\"{s}\"}}",
            .{ agent_name, args.to, args.text },
        ) catch return error.BodyTooLarge
    else
        std.fmt.bufPrint(
            &body_buf,
            "{{\"channel\":\"telegram\",\"to\":\"{s}\",\"text\":\"{s}\"}}",
            .{ args.to, args.text },
        ) catch return error.BodyTooLarge;

    const result = http_client.send(
        allocator,
        io,
        .{
            .method = .POST,
            .url = url,
            .bearer = args.bearer,
            .json_body = body,
        },
        null,
        .{},
    ) catch |e| switch (e) {
        error.GatewayDown => {
            try err.print(
                "gateway not reachable at {s} — start it with: tigerclaw gateway start\n",
                .{args.base_url},
            );
            return e;
        },
        else => return e,
    };

    try out.print("sent (status {d})\n", .{result.status});
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: list" {
    const argv = [_][]const u8{"list"};
    try testing.expectEqual(Subcommand.list, try parse(&argv));
}

test "parse: status" {
    const argv = [_][]const u8{"status"};
    try testing.expectEqual(Subcommand.status, try parse(&argv));
}

test "parse: telegram enable" {
    const argv = [_][]const u8{ "telegram", "enable" };
    try testing.expectEqual(Subcommand.telegram_enable, try parse(&argv));
}

test "parse: telegram disable" {
    const argv = [_][]const u8{ "telegram", "disable" };
    try testing.expectEqual(Subcommand.telegram_disable, try parse(&argv));
}

test "parse: telegram test with --to and --text" {
    const argv = [_][]const u8{ "telegram", "test", "--to", "123", "--text", "hi" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("123", sub.telegram_test.to);
    try testing.expectEqualStrings("hi", sub.telegram_test.text);
    try testing.expectEqualStrings("http://127.0.0.1:8765", sub.telegram_test.base_url);
    try testing.expect(sub.telegram_test.bearer == null);
}

test "parse: telegram test with --agent" {
    const argv = [_][]const u8{ "telegram", "test", "--to", "123", "--text", "hi", "--agent", "reviewer-01" };
    const sub = try parse(&argv);
    try testing.expectEqualStrings("123", sub.telegram_test.to);
    try testing.expectEqualStrings("hi", sub.telegram_test.text);
    try testing.expect(sub.telegram_test.agent != null);
    try testing.expectEqualStrings("reviewer-01", sub.telegram_test.agent.?);
}

test "parse: telegram test without --agent leaves it null" {
    const argv = [_][]const u8{ "telegram", "test", "--to", "123", "--text", "hi" };
    const sub = try parse(&argv);
    try testing.expectEqual(@as(?[]const u8, null), sub.telegram_test.agent);
}

test "parse: telegram test missing both fields → TelegramTestMissingFields" {
    const argv = [_][]const u8{ "telegram", "test" };
    try testing.expectError(error.TelegramTestMissingFields, parse(&argv));
}

test "parse: empty argv → MissingSubcommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubcommand, parse(&argv));
}

test "parse: unknown verb → UnknownSubcommand" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

test "parse: telegram test with bogus flag → UnknownFlag" {
    const argv = [_][]const u8{ "telegram", "test", "--to", "1", "--text", "hi", "--bogus" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "run: list emits a row mentioning telegram + disabled" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    var ew: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .list, &ow, &ew);
    const out = ow.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "telegram") != null);
    try testing.expect(std.mem.indexOf(u8, out, "disabled") != null);
}

test "run: status emits a row mentioning telegram + not running" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    var ew: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .status, &ow, &ew);
    const out = ow.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "telegram") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not running") != null);
}

test "run: telegram_enable says enabled" {
    var out_buf: [128]u8 = undefined;
    var err_buf: [128]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    var ew: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .telegram_enable, &ow, &ew);
    try testing.expect(std.mem.indexOf(u8, ow.buffered(), "enabled") != null);
}

test "run: telegram_disable says disabled" {
    var out_buf: [128]u8 = undefined;
    var err_buf: [128]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out_buf);
    var ew: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .telegram_disable, &ow, &ew);
    try testing.expect(std.mem.indexOf(u8, ow.buffered(), "disabled") != null);
}
