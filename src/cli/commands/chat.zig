//! `tigerclaw chat` — minimal interactive REPL over the gateway.
//!
//! Reads a line from stdin, prints a colored agent prefix, delegates the
//! turn to `commands.agent.run` (same SSE renderer, same SIGINT handler,
//! same cancel-on-Ctrl-C path), then loops. `/quit`, `/exit`, EOF, or an
//! empty stdin all terminate cleanly.

const std = @import("std");
const agent_cmd = @import("agent.zig");

pub const Options = struct {
    base_url: []const u8,
    agent_name: []const u8 = "tiger",
    session_id: []const u8 = "tiger",
    bearer: ?[]const u8 = null,
    /// Where prompts and replies are rendered (stdout in main.zig).
    out: *std.Io.Writer,
    /// Where the user's input lines arrive from (stdin in main.zig).
    in: *std.Io.Reader,
    /// Set to true when stdout is a TTY; controls ANSI color emission.
    color: bool = true,
};

pub const Error = agent_cmd.Error;

const ANSI_RESET = "\x1b[0m";
const ANSI_DIM = "\x1b[2m";
const ANSI_BOLD = "\x1b[1m";

/// Six 256-color foreground codes selected for legibility on dark and
/// light terminals. Indexed by Wyhash(agent_name) so the same agent
/// always renders the same color across turns and across processes.
const palette = [_][]const u8{
    "\x1b[38;5;208m", // orange (tiger default)
    "\x1b[38;5;141m", // violet
    "\x1b[38;5;43m", // teal
    "\x1b[38;5;220m", // amber
    "\x1b[38;5;204m", // pink
    "\x1b[38;5;75m", // sky
};

fn colorFor(name: []const u8) []const u8 {
    if (name.len == 0) return palette[0];
    const h = std.hash.Wyhash.hash(0, name);
    return palette[@intCast(h % palette.len)];
}

/// Run the REPL until the user quits, EOF, or a fatal error from the
/// agent runner. Non-fatal per-turn errors are printed and the loop
/// continues so a transient gateway hiccup doesn't kill the session.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) Error!void {
    agent_cmd.installInterruptHandler();

    writeBanner(opts) catch return error.InvalidResponse;

    while (true) {
        writePrompt(opts) catch return error.InvalidResponse;
        opts.out.flush() catch return error.InvalidResponse;

        // takeDelimiter returns null at EOF (Ctrl-D, closed pipe, etc.) so
        // we can't get stuck spinning on a half-closed stream.
        const maybe = opts.in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                opts.out.writeAll("chat: line too long, ignored\n") catch {};
                continue;
            },
            else => return error.InvalidResponse,
        };
        const raw = maybe orelse {
            opts.out.writeAll("\n") catch {};
            return;
        };
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");

        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) return;

        writeAgentPrefix(opts) catch return error.InvalidResponse;

        const turn_opts: agent_cmd.Options = .{
            .base_url = opts.base_url,
            .agent_name = opts.agent_name,
            .message = line,
            .session_id = opts.session_id,
            .bearer = opts.bearer,
            .out = opts.out,
        };

        agent_cmd.run(allocator, io, turn_opts) catch |err| switch (err) {
            // Ctrl-C during a turn cancels the turn but keeps the REPL alive.
            error.Interrupted => {
                opts.out.writeAll("\n(turn interrupted)\n") catch {};
                continue;
            },
            // Transient transport problems — report and continue.
            error.GatewayDown => {
                opts.out.writeAll("\nchat: gateway unreachable\n") catch {};
                continue;
            },
            error.InvalidResponse => {
                opts.out.writeAll("\nchat: invalid gateway response\n") catch {};
                continue;
            },
            // Fatal: bubble up so the shell sees a real exit code.
            else => |e| return e,
        };
        // Make the reply visible before we draw the next prompt — the
        // underlying writer is buffered and only auto-flushes on a full
        // buffer or process exit otherwise.
        opts.out.flush() catch {};
    }
}

fn writeBanner(opts: Options) std.Io.Writer.Error!void {
    if (opts.color) {
        try opts.out.print(
            "{s}tigerclaw chat{s}{s} — talking to {s}{s}{s}{s} via {s}{s}{s}\n" ++
                "{s}type /quit to leave, Ctrl-C cancels a turn{s}\n\n",
            .{
                ANSI_BOLD,                 ANSI_RESET,
                ANSI_DIM,                  ANSI_RESET,
                colorFor(opts.agent_name), opts.agent_name,
                ANSI_RESET,                ANSI_DIM,
                opts.base_url,             ANSI_RESET,
                ANSI_DIM,                  ANSI_RESET,
            },
        );
    } else {
        try opts.out.print(
            "tigerclaw chat — talking to {s} via {s}\ntype /quit to leave, Ctrl-C cancels a turn\n\n",
            .{ opts.agent_name, opts.base_url },
        );
    }
}

fn writePrompt(opts: Options) std.Io.Writer.Error!void {
    if (opts.color) {
        try opts.out.writeAll("\x1b[38;5;39myou ›\x1b[0m ");
    } else {
        try opts.out.writeAll("you > ");
    }
}

fn writeAgentPrefix(opts: Options) std.Io.Writer.Error!void {
    if (opts.color) {
        try opts.out.print("{s}{s} »{s} ", .{ colorFor(opts.agent_name), opts.agent_name, ANSI_RESET });
    } else {
        try opts.out.print("{s} > ", .{opts.agent_name});
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "colorFor: same name maps to same palette slot" {
    const a = colorFor("tiger");
    const b = colorFor("tiger");
    try testing.expectEqualStrings(a, b);
}

test "colorFor: different names usually map to different slots" {
    // Not strictly different (palette has 6 entries, hash collisions exist),
    // but at least one of these pairs must differ.
    const t = colorFor("tiger");
    const s = colorFor("sage");
    const b = colorFor("bolt");
    const all_same = std.mem.eql(u8, t, s) and std.mem.eql(u8, s, b);
    try testing.expect(!all_same);
}

test "colorFor: empty name returns first palette entry" {
    try testing.expectEqualStrings(palette[0], colorFor(""));
}
