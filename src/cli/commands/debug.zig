//! `tigerclaw debug` — non-TUI entry points for stepping through
//! the runtime under a debugger.
//!
//! Subcommands today:
//!
//!   runner --message "<text>" [--agent <name>] [--session-id <id>]
//!     Loads the LiveAgentRunner with the same code path the TUI
//!     uses, runs exactly one turn against the live provider, and
//!     prints the final assistant output to stdout. No alt-screen,
//!     no streaming sinks — just a plain process you can attach
//!     `lldb` to and step through `runTurn` without the TUI
//!     fighting for the terminal.
//!
//! Recommended workflow:
//!
//!   zig build
//!   lldb -- zig-out/bin/tigerclaw debug runner --message "whats the time?"
//!   (lldb) breakpoint set --file live_runner.zig --line 380
//!   (lldb) run
//!   (lldb) frame variable messages
//!
//! The runner's transcript persists across runs in the same way as
//! the TUI session (via the in-process context engine seeded from
//! `req.session_id`). Pass `--session-id` to share or reset history.

const std = @import("std");
const live_runner = @import("live_runner.zig");
const harness = @import("../../harness/root.zig");

pub const Subcommand = union(enum) {
    runner: RunnerArgs,
};

pub const RunnerArgs = struct {
    /// Agent name resolved against `~/.tigerclaw/agents/<name>/`.
    agent: []const u8 = "tiger",
    /// User message for the single turn we'll run.
    message: []const u8,
    /// Session id — shares history with prior runs that used the
    /// same value. Default keeps each invocation isolated.
    session_id: []const u8 = "debug-runner",
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
    MissingMessage,
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    if (std.mem.eql(u8, argv[0], "runner")) return parseRunner(argv[1..]);
    return error.UnknownSubcommand;
}

fn parseRunner(rest: []const []const u8) ParseError!Subcommand {
    var args: RunnerArgs = .{ .message = "" };
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--agent")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.agent = rest[i];
        } else if (std.mem.eql(u8, a, "--message") or std.mem.eql(u8, a, "-m")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.message = rest[i];
        } else if (std.mem.eql(u8, a, "--session-id")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.session_id = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }
    if (args.message.len == 0) return error.MissingMessage;
    return .{ .runner = args };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    sub: Subcommand,
    home: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    switch (sub) {
        .runner => |args| try runRunner(allocator, io, args, home, out, err),
    }
}

fn runRunner(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: RunnerArgs,
    home: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !void {
    var live = live_runner.LiveAgentRunner.load(
        allocator,
        io,
        args.agent,
        "",
        home,
    ) catch |e| {
        try err.print("debug runner: could not load agent '{s}': {s}\n", .{ args.agent, @errorName(e) });
        return;
    };
    defer live.deinit();

    var runner = live.runner();
    const result = runner.run(.{
        .session_id = args.session_id,
        .input = args.message,
    }) catch |e| {
        try err.print("debug runner: turn failed: {s}\n", .{@errorName(e)});
        return;
    };

    try out.print("--- final output ({d} bytes, completed={any}) ---\n", .{
        result.output.len,
        result.completed,
    });
    try out.writeAll(result.output);
    if (result.output.len > 0 and result.output[result.output.len - 1] != '\n') {
        try out.writeByte('\n');
    }
}
