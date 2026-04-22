//! CLI argument parsing for the top-level `tigerclaw` binary.
//!
//! This commit wires only `--version` and `--help`. Subcommands (`run`,
//! `doctor`, `list`, etc.) are added as entrypoints land.

const std = @import("std");

pub const version_string = "0.0.0";

pub const Command = union(enum) {
    version,
    help,
    unknown: []const u8,
};

pub const ParseError = error{
    MissingCommand,
};

/// Parse argv[1..]. `argv` must not include the program name.
pub fn parse(argv: []const []const u8) ParseError!Command {
    if (argv.len == 0) return error.MissingCommand;

    const first = argv[0];
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        return .version;
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .help;
    }
    return .{ .unknown = first };
}

pub const help_text =
    \\tigerclaw — agent runtime
    \\
    \\Usage:
    \\  tigerclaw <command> [options]
    \\
    \\Options:
    \\  -h, --help     Print this message
    \\  -V, --version  Print the version and exit
    \\
    \\Commands are added as subsystems land. See docs/ARCHITECTURE.md.
    \\
;

pub fn printVersion(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("tigerclaw {s}\n", .{version_string});
}

pub fn printHelp(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(help_text);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: --version" {
    const argv = [_][]const u8{"--version"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: -V short form" {
    const argv = [_][]const u8{"-V"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: --help" {
    const argv = [_][]const u8{"--help"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: -h short form" {
    const argv = [_][]const u8{"-h"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: unknown flag returns .unknown with the flag text" {
    const argv = [_][]const u8{"--nope"};
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("--nope", cmd.unknown);
}

test "parse: empty argv returns MissingCommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingCommand, parse(&argv));
}

test "printVersion writes the expected string" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printVersion(&w);
    try testing.expectEqualStrings("tigerclaw 0.0.0\n", w.buffered());
}

test "printHelp starts with the expected banner and mentions both flags" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printHelp(&w);
    const written = w.buffered();
    try testing.expect(std.mem.startsWith(u8, written, "tigerclaw — agent runtime\n"));
    try testing.expect(std.mem.indexOf(u8, written, "--version") != null);
    try testing.expect(std.mem.indexOf(u8, written, "--help") != null);
}
