//! CLI front door.
//!
//! Historically `src/cli.zig` owned argv parsing and help-text rendering
//! as a flat if/else chain. This module keeps that public surface
//! stable while moving the underlying machinery to a descriptor-driven
//! dispatcher (`descriptor.zig`) and a presentation layer
//! (`presentation.zig`). Concrete subcommands register into
//! `command_table`; `parse` resolves argv[0] against the table and
//! folds the result back into the legacy `Command` union so existing
//! callers keep working.
//!
//! As verbs are ported over in later commits, they will attach real
//! handlers via the descriptor table instead of growing the union.

const std = @import("std");
const version = @import("../version.zig");

pub const descriptor = @import("descriptor.zig");
pub const presentation = @import("presentation.zig");

pub const version_string = version.string;

pub const Command = union(enum) {
    version,
    help,
    unknown: []const u8,
};

pub const ParseError = error{
    MissingCommand,
};

/// Top-level command table. Kept minimal while individual verbs live
/// in the legacy `Command` union; later commits grow this directly.
pub const command_table = [_]descriptor.CommandDescriptor{
    .{ .name = "version", .summary = "Print the version and exit" },
    .{ .name = "help", .summary = "Print this message" },
};

/// Parse argv[1..]. `argv` must not include the program name.
///
/// Legacy flag forms (`--version`, `-V`, `--help`, `-h`) are normalised
/// into the same `Command` values the dispatcher produces for the
/// equivalent verbs. Anything else falls through to `.unknown` so the
/// caller can print a usage error with the offending token.
pub fn parse(argv: []const []const u8) ParseError!Command {
    if (argv.len == 0) return error.MissingCommand;

    const first = argv[0];

    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        return .version;
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .help;
    }

    const match = descriptor.resolve(&command_table, argv) catch |err| switch (err) {
        error.MissingCommand => return error.MissingCommand,
        error.UnknownCommand => return .{ .unknown = first },
    };

    if (std.mem.eql(u8, match.descriptor.name, "version")) return .version;
    if (std.mem.eql(u8, match.descriptor.name, "help")) return .help;

    // A descriptor with no legacy mapping means the verb is expected
    // to have its own handler attached; today there are none. Fall
    // through to `.unknown` so callers surface a clear error rather
    // than silently accepting the token.
    return .{ .unknown = first };
}

pub fn printVersion(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("tigerclaw {s}\n", .{version_string});
}

pub fn printHelp(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try presentation.writeBanner(w);
    try w.writeAll("\nUsage:\n  tigerclaw <command> [options]\n\n");

    try w.writeAll("Options:\n");
    const OptionRow = struct { name: []const u8, summary: []const u8 };
    const options = [_]OptionRow{
        .{ .name = "-h, --help", .summary = "Print this message" },
        .{ .name = "-V, --version", .summary = "Print the version and exit" },
    };
    try presentation.writeTable(w, OptionRow, &options, 14);

    try w.writeAll("\nCommands:\n");
    try presentation.writeTable(
        w,
        descriptor.CommandDescriptor,
        &command_table,
        14,
    );

    try w.writeAll("\nMore commands land as subsystems are added. See docs/ARCHITECTURE.md.\n");
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: --version flag" {
    const argv = [_][]const u8{"--version"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: -V short flag" {
    const argv = [_][]const u8{"-V"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: --help flag" {
    const argv = [_][]const u8{"--help"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: -h short flag" {
    const argv = [_][]const u8{"-h"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: version verb via descriptor table" {
    const argv = [_][]const u8{"version"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: help verb via descriptor table" {
    const argv = [_][]const u8{"help"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: unknown token returns .unknown" {
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
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "tigerclaw {s}\n", .{version.string});
    try testing.expectEqualStrings(expected, w.buffered());
}

test "printHelp: mentions banner, both flags, and both table verbs" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printHelp(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "tigerclaw — agent runtime") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--version") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try testing.expect(std.mem.indexOf(u8, out, "version") != null);
    try testing.expect(std.mem.indexOf(u8, out, "help") != null);
}

test {
    testing.refAllDecls(@This());
}
