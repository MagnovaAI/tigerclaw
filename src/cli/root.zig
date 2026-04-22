//! CLI front door.
//!
//! Routes top-level argv into either a legacy `Command` union value
//! (for verbs whose behaviour is inlined in `main.zig`) or a typed
//! handler call site (for verbs implemented in `src/cli/commands/*`).

const std = @import("std");
const version = @import("../version.zig");

pub const descriptor = @import("descriptor.zig");
pub const presentation = @import("presentation.zig");
pub const commands = struct {
    pub const doctor = @import("commands/doctor.zig");
    pub const completion = @import("commands/completion.zig");
};

pub const version_string = version.string;

pub const Command = union(enum) {
    version,
    help,
    doctor,
    completion: commands.completion.Shell,
    unknown: []const u8,
};

pub const ParseError = error{
    MissingCommand,
    CompletionMissingShell,
    CompletionUnknownShell,
};

/// Top-level command table. Summaries feed the help screen and shell
/// completion generators.
pub const command_table = [_]descriptor.CommandDescriptor{
    .{ .name = "version", .summary = "Print the version and exit" },
    .{ .name = "help", .summary = "Print this message" },
    .{ .name = "doctor", .summary = "Print a short environment report" },
    .{ .name = "completion", .summary = "Print a shell completion script (bash|zsh|fish)" },
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

    const match = descriptor.resolve(&command_table, argv) catch |err| switch (err) {
        error.MissingCommand => return error.MissingCommand,
        error.UnknownCommand => return .{ .unknown = first },
    };

    if (std.mem.eql(u8, match.descriptor.name, "version")) return .version;
    if (std.mem.eql(u8, match.descriptor.name, "help")) return .help;
    if (std.mem.eql(u8, match.descriptor.name, "doctor")) return .doctor;
    if (std.mem.eql(u8, match.descriptor.name, "completion")) {
        if (match.argv.len < 2) return error.CompletionMissingShell;
        const shell = commands.completion.parseShell(match.argv[1]) catch return error.CompletionUnknownShell;
        return .{ .completion = shell };
    }

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

test "parse: doctor verb via descriptor table" {
    const argv = [_][]const u8{"doctor"};
    try testing.expectEqual(Command.doctor, try parse(&argv));
}

test "parse: completion bash → Command.completion{.bash}" {
    const argv = [_][]const u8{ "completion", "bash" };
    const cmd = try parse(&argv);
    try testing.expectEqual(commands.completion.Shell.bash, cmd.completion);
}

test "parse: completion without shell returns CompletionMissingShell" {
    const argv = [_][]const u8{"completion"};
    try testing.expectError(error.CompletionMissingShell, parse(&argv));
}

test "parse: completion with unknown shell returns CompletionUnknownShell" {
    const argv = [_][]const u8{ "completion", "tcsh" };
    try testing.expectError(error.CompletionUnknownShell, parse(&argv));
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

test "printHelp: mentions banner, both flags, and the verbs in the table" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printHelp(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "tigerclaw — agent runtime") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--version") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doctor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "completion") != null);
}

test {
    testing.refAllDecls(@This());
}
