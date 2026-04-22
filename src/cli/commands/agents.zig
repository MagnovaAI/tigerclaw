//! `tigerclaw agents <verb>` sub-verb parser.
//!
//! Parses the plural `agents` verb into one of the named sub-verbs:
//! `list`, `show`, `add`, `edit`, `delete`, `enable`, `disable`,
//! `talk`. Each carries the agent name as a positional where
//! required. Execution lives alongside the settings + registry
//! subsystems; this module is argv-only so it stays trivial to test.

const std = @import("std");

pub const Verb = union(enum) {
    list,
    show: []const u8,
    add: []const u8,
    edit: []const u8,
    delete: []const u8,
    enable: []const u8,
    disable: []const u8,
    /// `agents talk <name> -m MSG` — the name is captured here;
    /// flags are re-parsed by `agent_selector` once the verb hands
    /// control back to the caller.
    talk: TalkArgs,
};

pub const TalkArgs = struct {
    name: []const u8,
    /// Remaining argv positions after the agent name. Typically the
    /// caller runs `agent_selector.parse(rest)` on these.
    rest: []const []const u8,
};

pub const ParseError = error{
    MissingSubVerb,
    UnknownSubVerb,
    MissingAgentName,
};

/// Parse argv *after* the `agents` verb has been matched. `argv[0]`
/// is the sub-verb name (`list`, `show`, …) and everything after
/// belongs to that sub-verb.
pub fn parse(argv: []const []const u8) ParseError!Verb {
    if (argv.len == 0) return error.MissingSubVerb;

    const sub = argv[0];
    const rest = argv[1..];

    if (std.mem.eql(u8, sub, "list")) return .list;

    if (std.mem.eql(u8, sub, "talk")) {
        if (rest.len == 0) return error.MissingAgentName;
        return .{ .talk = .{ .name = rest[0], .rest = rest[1..] } };
    }

    // All other sub-verbs take exactly one positional: the agent name.
    if (std.mem.eql(u8, sub, "show") or
        std.mem.eql(u8, sub, "add") or
        std.mem.eql(u8, sub, "edit") or
        std.mem.eql(u8, sub, "delete") or
        std.mem.eql(u8, sub, "enable") or
        std.mem.eql(u8, sub, "disable"))
    {
        if (rest.len == 0) return error.MissingAgentName;
        const name = rest[0];
        if (std.mem.eql(u8, sub, "show")) return .{ .show = name };
        if (std.mem.eql(u8, sub, "add")) return .{ .add = name };
        if (std.mem.eql(u8, sub, "edit")) return .{ .edit = name };
        if (std.mem.eql(u8, sub, "delete")) return .{ .delete = name };
        if (std.mem.eql(u8, sub, "enable")) return .{ .enable = name };
        if (std.mem.eql(u8, sub, "disable")) return .{ .disable = name };
    }

    return error.UnknownSubVerb;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: agents list" {
    const argv = [_][]const u8{"list"};
    const v = try parse(&argv);
    try testing.expectEqual(Verb.list, v);
}

test "parse: agents show <name>" {
    const argv = [_][]const u8{ "show", "concierge" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("concierge", v.show);
}

test "parse: agents add <name>" {
    const argv = [_][]const u8{ "add", "newbot" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("newbot", v.add);
}

test "parse: agents edit <name>" {
    const argv = [_][]const u8{ "edit", "concierge" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("concierge", v.edit);
}

test "parse: agents delete <name>" {
    const argv = [_][]const u8{ "delete", "oldbot" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("oldbot", v.delete);
}

test "parse: agents enable <name>" {
    const argv = [_][]const u8{ "enable", "x" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("x", v.enable);
}

test "parse: agents disable <name>" {
    const argv = [_][]const u8{ "disable", "x" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("x", v.disable);
}

test "parse: agents talk <name> -m MSG hands the rest back" {
    const argv = [_][]const u8{ "talk", "concierge", "-m", "hi" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("concierge", v.talk.name);
    try testing.expectEqual(@as(usize, 2), v.talk.rest.len);
    try testing.expectEqualStrings("-m", v.talk.rest[0]);
    try testing.expectEqualStrings("hi", v.talk.rest[1]);
}

test "parse: agents talk without a name returns MissingAgentName" {
    const argv = [_][]const u8{"talk"};
    try testing.expectError(error.MissingAgentName, parse(&argv));
}

test "parse: agents show without a name returns MissingAgentName" {
    const argv = [_][]const u8{"show"};
    try testing.expectError(error.MissingAgentName, parse(&argv));
}

test "parse: empty argv returns MissingSubVerb" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubVerb, parse(&argv));
}

test "parse: unknown sub-verb returns UnknownSubVerb" {
    const argv = [_][]const u8{"wiggle"};
    try testing.expectError(error.UnknownSubVerb, parse(&argv));
}
