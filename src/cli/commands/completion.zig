//! `tigerclaw completion <shell>` — print a shell completion script.
//!
//! This commit ships minimal completion stubs for bash, zsh, and fish
//! that complete the top-level verb list against the descriptor table
//! passed in. Future commits can teach completion about subcommand
//! verbs and flag values as real subsystems land.

const std = @import("std");
const descriptor = @import("../descriptor.zig");

pub const Shell = enum { bash, zsh, fish };

pub const ShellParseError = error{UnknownShell};

pub fn parseShell(name: []const u8) ShellParseError!Shell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    return error.UnknownShell;
}

pub fn write(
    w: *std.Io.Writer,
    shell: Shell,
    table: []const descriptor.CommandDescriptor,
) std.Io.Writer.Error!void {
    switch (shell) {
        .bash => try writeBash(w, table),
        .zsh => try writeZsh(w, table),
        .fish => try writeFish(w, table),
    }
}

fn writeCommaSeparated(
    w: *std.Io.Writer,
    table: []const descriptor.CommandDescriptor,
    separator: []const u8,
) std.Io.Writer.Error!void {
    for (table, 0..) |entry, i| {
        if (i > 0) try w.writeAll(separator);
        try w.writeAll(entry.name);
    }
}

fn writeBash(
    w: *std.Io.Writer,
    table: []const descriptor.CommandDescriptor,
) std.Io.Writer.Error!void {
    try w.writeAll("# tigerclaw bash completion\n");
    try w.writeAll("_tigerclaw() {\n  local cur=\"${COMP_WORDS[COMP_CWORD]}\"\n  local verbs=\"");
    try writeCommaSeparated(w, table, " ");
    try w.writeAll("\"\n  COMPREPLY=( $(compgen -W \"$verbs\" -- \"$cur\") )\n}\ncomplete -F _tigerclaw tigerclaw\n");
}

fn writeZsh(
    w: *std.Io.Writer,
    table: []const descriptor.CommandDescriptor,
) std.Io.Writer.Error!void {
    try w.writeAll("#compdef tigerclaw\n_tigerclaw() {\n  local -a verbs\n  verbs=(\n");
    for (table) |entry| {
        try w.print("    '{s}:{s}'\n", .{ entry.name, entry.summary });
    }
    try w.writeAll("  )\n  _describe 'command' verbs\n}\n_tigerclaw \"$@\"\n");
}

fn writeFish(
    w: *std.Io.Writer,
    table: []const descriptor.CommandDescriptor,
) std.Io.Writer.Error!void {
    try w.writeAll("# tigerclaw fish completion\n");
    for (table) |entry| {
        try w.print(
            "complete -c tigerclaw -f -n \"not __fish_seen_subcommand_from {s}\" -a '{s}' -d '{s}'\n",
            .{ entry.name, entry.name, entry.summary },
        );
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseShell: bash/zsh/fish map to their enum tags" {
    try testing.expectEqual(Shell.bash, try parseShell("bash"));
    try testing.expectEqual(Shell.zsh, try parseShell("zsh"));
    try testing.expectEqual(Shell.fish, try parseShell("fish"));
}

test "parseShell: unknown shell returns UnknownShell" {
    try testing.expectError(error.UnknownShell, parseShell("tcsh"));
}

test "write bash: lists all verbs in the compgen -W string" {
    const table = [_]descriptor.CommandDescriptor{
        .{ .name = "version", .summary = "Print the version" },
        .{ .name = "doctor", .summary = "Environment report" },
    };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .bash, &table);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "version doctor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "complete -F _tigerclaw tigerclaw") != null);
}

test "write zsh: emits _describe with name:summary pairs" {
    const table = [_]descriptor.CommandDescriptor{
        .{ .name = "version", .summary = "Print the version" },
    };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .zsh, &table);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "#compdef tigerclaw") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'version:Print the version'") != null);
}

test "write fish: emits one complete line per verb" {
    const table = [_]descriptor.CommandDescriptor{
        .{ .name = "version", .summary = "Print the version" },
        .{ .name = "help", .summary = "Print help" },
    };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .fish, &table);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "-a 'version'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-a 'help'") != null);
}
