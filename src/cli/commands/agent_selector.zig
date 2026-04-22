//! Parse the `--agent <name>` selector shared by the `agent` and
//! `agents talk` verbs.
//!
//! The rule (rev 3): the selector is a strict flag. No positional
//! `<name>` arg, no `@`-sigil, no implicit fallback other than
//! `agents.default` from config. When `--agent` is omitted, the
//! caller looks up the configured default; when it is present but
//! unknown, the caller prints a usage error listing the known agents.
//!
//! This module does *not* touch config. It only parses argv. The
//! caller combines the parsed value with an `AgentRegistry.resolveSelector`
//! call to produce a concrete agent.

const std = @import("std");

pub const Parsed = struct {
    /// Value of `--agent <name>`; null when the flag was omitted.
    agent_name: ?[]const u8,
    /// Value of `-m <message>` / `--message <msg>`; null when omitted.
    message: ?[]const u8,
    /// argv positions the caller may continue to consume (typically
    /// verb-specific trailing args). For plain `agent -m MSG --agent X`
    /// this is empty.
    rest: []const []const u8,
};

pub const ParseError = error{
    MissingFlagValue,
    UnknownFlag,
    RepeatedFlag,
};

/// Parse argv *after* the verb has been matched. `argv[0]` must
/// already be the first flag, not the verb name.
pub fn parse(argv: []const []const u8) ParseError!Parsed {
    var agent_name: ?[]const u8 = null;
    var message: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (std.mem.eql(u8, a, "--agent")) {
            if (agent_name != null) return error.RepeatedFlag;
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            agent_name = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--message")) {
            if (message != null) return error.RepeatedFlag;
            if (i + 1 >= argv.len) return error.MissingFlagValue;
            message = argv[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` belongs to the caller.
            return .{
                .agent_name = agent_name,
                .message = message,
                .rest = argv[i + 1 ..],
            };
        }
        return error.UnknownFlag;
    }

    return .{ .agent_name = agent_name, .message = message, .rest = &.{} };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: bare agent -m MSG leaves agent_name null" {
    const argv = [_][]const u8{ "-m", "hi" };
    const p = try parse(&argv);
    try testing.expect(p.agent_name == null);
    try testing.expectEqualStrings("hi", p.message.?);
    try testing.expectEqual(@as(usize, 0), p.rest.len);
}

test "parse: --agent <name> captures the name" {
    const argv = [_][]const u8{ "--agent", "code-reviewer", "-m", "hi" };
    const p = try parse(&argv);
    try testing.expectEqualStrings("code-reviewer", p.agent_name.?);
    try testing.expectEqualStrings("hi", p.message.?);
}

test "parse: --agent and -m order-independent" {
    const argv = [_][]const u8{ "-m", "go", "--agent", "concierge" };
    const p = try parse(&argv);
    try testing.expectEqualStrings("concierge", p.agent_name.?);
    try testing.expectEqualStrings("go", p.message.?);
}

test "parse: --message long form" {
    const argv = [_][]const u8{ "--message", "yo", "--agent", "x" };
    const p = try parse(&argv);
    try testing.expectEqualStrings("yo", p.message.?);
}

test "parse: --agent without value returns MissingFlagValue" {
    const argv = [_][]const u8{"--agent"};
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "parse: -m without value returns MissingFlagValue" {
    const argv = [_][]const u8{"-m"};
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "parse: repeated --agent flag returns RepeatedFlag" {
    const argv = [_][]const u8{ "--agent", "a", "--agent", "b" };
    try testing.expectError(error.RepeatedFlag, parse(&argv));
}

test "parse: unknown flag returns UnknownFlag (no positional fallback)" {
    const argv = [_][]const u8{ "concierge", "-m", "hi" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: `--` ends flag parsing and hands the rest back" {
    const argv = [_][]const u8{ "--agent", "x", "--", "file.txt", "arg2" };
    const p = try parse(&argv);
    try testing.expectEqualStrings("x", p.agent_name.?);
    try testing.expectEqual(@as(usize, 2), p.rest.len);
    try testing.expectEqualStrings("file.txt", p.rest[0]);
    try testing.expectEqualStrings("arg2", p.rest[1]);
}

test "parse: empty argv gives empty Parsed" {
    const argv = [_][]const u8{};
    const p = try parse(&argv);
    try testing.expect(p.agent_name == null);
    try testing.expect(p.message == null);
    try testing.expectEqual(@as(usize, 0), p.rest.len);
}
