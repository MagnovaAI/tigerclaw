//! `tigerclaw sessions <verb>` sub-verb parser.
//!
//! Verbs mirror the classic list/show/tail/delete surface:
//!
//!   list    — print all known sessions
//!   show    — print the full state of a single session
//!   tail    — stream turn events for a session
//!   delete  — remove a session
//!
//! Execution lives beside the HTTP client and the disk-fallback
//! reader. This module stays argv-only.

const std = @import("std");

pub const Verb = union(enum) {
    list: ListOptions,
    show: ShowOptions,
    tail: TailOptions,
    delete: DeleteOptions,
};

pub const ListOptions = struct {
    /// Filter by agent name; null means "all agents".
    agent_name: ?[]const u8 = null,
    /// Filter by channel id; null means "all channels".
    channel_id: ?[]const u8 = null,
};

pub const ShowOptions = struct {
    id: []const u8,
};

pub const TailOptions = struct {
    id: []const u8,
    /// When true, keep the stream open and print new turn events as
    /// they arrive. When false, print any buffered events and exit.
    follow: bool = false,
};

pub const DeleteOptions = struct {
    id: []const u8,
    /// When true, delete the session even if in-flight turns exist.
    force: bool = false,
};

pub const ParseError = error{
    MissingSubVerb,
    UnknownSubVerb,
    MissingSessionId,
    MissingFlagValue,
    UnknownFlag,
};

pub fn parse(argv: []const []const u8) ParseError!Verb {
    if (argv.len == 0) return error.MissingSubVerb;

    const sub = argv[0];
    const rest = argv[1..];

    if (std.mem.eql(u8, sub, "list")) return .{ .list = try parseList(rest) };
    if (std.mem.eql(u8, sub, "show")) return .{ .show = try parseShow(rest) };
    if (std.mem.eql(u8, sub, "tail")) return .{ .tail = try parseTail(rest) };
    if (std.mem.eql(u8, sub, "delete")) return .{ .delete = try parseDelete(rest) };
    return error.UnknownSubVerb;
}

fn parseList(argv: []const []const u8) ParseError!ListOptions {
    var opts: ListOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--agent")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            opts.agent_name = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--channel")) {
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            opts.channel_id = argv[i + 1];
            i += 1;
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

fn parseShow(argv: []const []const u8) ParseError!ShowOptions {
    if (argv.len == 0) return error.MissingSessionId;
    if (argv.len > 1) return error.UnknownFlag;
    return .{ .id = argv[0] };
}

fn parseTail(argv: []const []const u8) ParseError!TailOptions {
    if (argv.len == 0) return error.MissingSessionId;
    var opts: TailOptions = .{ .id = argv[0] };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f")) {
            opts.follow = true;
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

fn parseDelete(argv: []const []const u8) ParseError!DeleteOptions {
    if (argv.len == 0) return error.MissingSessionId;
    var opts: DeleteOptions = .{ .id = argv[0] };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            opts.force = true;
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: sessions list with no filters" {
    const argv = [_][]const u8{"list"};
    const v = try parse(&argv);
    try testing.expect(v.list.agent_name == null);
    try testing.expect(v.list.channel_id == null);
}

test "parse: sessions list --agent X --channel Y" {
    const argv = [_][]const u8{ "list", "--agent", "cli", "--channel", "stdin" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("cli", v.list.agent_name.?);
    try testing.expectEqualStrings("stdin", v.list.channel_id.?);
}

test "parse: sessions list --agent without value → MissingFlagValue" {
    const argv = [_][]const u8{ "list", "--agent" };
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "parse: sessions show <id>" {
    const argv = [_][]const u8{ "show", "s1" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("s1", v.show.id);
}

test "parse: sessions show without id → MissingSessionId" {
    const argv = [_][]const u8{"show"};
    try testing.expectError(error.MissingSessionId, parse(&argv));
}

test "parse: sessions show with extra token → UnknownFlag" {
    const argv = [_][]const u8{ "show", "s1", "--extra" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: sessions tail <id>" {
    const argv = [_][]const u8{ "tail", "s1" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("s1", v.tail.id);
    try testing.expect(!v.tail.follow);
}

test "parse: sessions tail <id> --follow" {
    const argv = [_][]const u8{ "tail", "s1", "--follow" };
    const v = try parse(&argv);
    try testing.expect(v.tail.follow);
}

test "parse: sessions tail -f short form" {
    const argv = [_][]const u8{ "tail", "s1", "-f" };
    const v = try parse(&argv);
    try testing.expect(v.tail.follow);
}

test "parse: sessions delete <id>" {
    const argv = [_][]const u8{ "delete", "s1" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("s1", v.delete.id);
    try testing.expect(!v.delete.force);
}

test "parse: sessions delete <id> --force" {
    const argv = [_][]const u8{ "delete", "s1", "--force" };
    const v = try parse(&argv);
    try testing.expect(v.delete.force);
}

test "parse: sessions empty argv → MissingSubVerb" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubVerb, parse(&argv));
}

test "parse: sessions unknown sub-verb → UnknownSubVerb" {
    const argv = [_][]const u8{"dance"};
    try testing.expectError(error.UnknownSubVerb, parse(&argv));
}
