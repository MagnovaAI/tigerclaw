//! Gateway startup banner in a compact one-liner style.
//!
//! Shape:
//!
//!     🐯 tigerclaw <version> (<commit>) — <tagline>
//!
//!     HH:MM:SS [gateway] agent model: provider/model
//!     HH:MM:SS [gateway] listening on http://host:port
//!     HH:MM:SS [gateway] ready (N agents: a, b, c)
//!     HH:MM:SS [gateway] Ctrl+C to stop
//!
//! The banner line itself is emitted once. Subsequent runtime
//! events come through `std.log.scoped(.gateway)` via the shared
//! formatter. This module only owns the first-impression surface.

const std = @import("std");
const builtin = @import("builtin");

// ── ANSI palette (white-bright / dim / accent triplet) ──

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const ITALIC = "\x1b[3m";
const WHITE_BRIGHT = "\x1b[97m";
const ORANGE = "\x1b[38;5;208m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const GREY = "\x1b[90m";

// ── Taglines ─────────────────────────────────────────────────

const TAGLINES = [_][]const u8{
    "You summoned the tiger. Bold. Let's hunt some bugs.",
    "🐯 *stretches* Alright, where are we pouncing today?",
    "Stripes on. Claws out. What's the target?",
    "Padding into your shell on silent paws. You won't hear a thing until it's done.",
    "I saw that TODO. It's prey now.",
    "Your jungle's a mess. Good thing I live for this.",
    "Pouncing on boilerplate since you opened the terminal.",
    "The logs are my waterhole. I drink deep, I see all.",
    "Purring quietly. Breathing slowly. Waiting for your command.",
    "You blink, I ship. That's the contract.",
    "Bash is the grass, bugs are the prey. I know these stripes by heart.",
    "Your config's weird. I like weird. Let's run it anyway.",
    "Ctrl+C won't work on me. I'm the predator. Try Ctrl+Z.",
    "Sharpening my claws on your backlog.",
    "I don't purr. The CPU does. Check your fans, pal.",
    "You wrote that regex at 2am. I've memorised it. We'll fix it together.",
    "One tiger. Zero dependencies. All terminal.",
    "Your .env is showing. I'll look away. Professionally.",
    "I hunt in the shell. You hunt in meetings. Division of labor.",
    "Roar mode: engaged. Volume: tastefully muted.",
    "You again. I was starting to miss the keyboard sounds.",
    "Tiger instinct says: this commit message needs work.",
    "I've been crouching in memory the whole time. Stealth mode.",
    "The prompt is the savanna. You're the wind. I'm the eyes.",
    "Less electron, more feline. Let's go.",
    "Every meow is a `warn`. Every growl is an `err`. Every purr is fine.",
    "I lick my paws between turns. It's a whole ritual.",
    "Silent as fur. Fast as claws. Loud only when you ask nicely.",
    "Keep typing. I'm three keystrokes ahead in the tall grass.",
};

fn nowEpochSecs() i64 {
    if (builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

fn nowNanoSeed() u64 {
    if (builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const secs: u64 = @intCast(@max(@as(i64, 0), ts.sec));
    const nsec: u64 = @intCast(@max(@as(i64, 0), ts.nsec));
    return secs *% 1_000_000_000 +% nsec;
}

/// Deterministic tagline pick for a given seed. Exposed so tests
/// can assert picks reproducibly.
pub fn pickTagline(seed: u64) []const u8 {
    const n: u64 = @intCast(TAGLINES.len);
    return TAGLINES[@intCast(seed % n)];
}

/// Randomized pick for the current run. Seeds a PRNG with the wall
/// clock at nanosecond resolution so every gateway start lands on
/// a fresh tagline, even restarts inside the same second.
pub fn currentTagline() []const u8 {
    if (builtin.is_test) return TAGLINES[0];
    var prng = std.Random.DefaultPrng.init(nowNanoSeed());
    return pickTagline(prng.random().int(u64));
}

// ── Timestamp ────────────────────────────────────────────────

fn writeTimestamp(w: *std.Io.Writer, color: bool) void {
    const ts = nowEpochSecs();
    if (ts < 0) {
        w.writeAll("??:??:?? ") catch return;
        return;
    }
    const day_secs: u64 = @intCast(@mod(ts, 86400));
    const h = day_secs / 3600;
    const m = (day_secs % 3600) / 60;
    const s = day_secs % 60;
    if (color) w.writeAll(GREY) catch return;
    w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(h)),
        @as(u32, @intCast(m)),
        @as(u32, @intCast(s)),
    }) catch return;
    if (color) w.writeAll(RESET) catch return;
    w.writeAll(" ") catch return;
}

// ── Banner line (one-liner) ──────────────────────────────────

pub const BannerOptions = struct {
    version: []const u8 = "dev",
    commit: []const u8 = "dev",
    host: []const u8 = "127.0.0.1",
    port: u16 = 8765,
    agent_model: ?[]const u8 = null,
    loaded_agents: []const []const u8 = &.{},
    verbose: bool = false,
    color: bool = false,
};

/// Emit the one-line brand banner + a small block of timestamped
/// [gateway] lines. `w` is the CLI stdout writer; runtime log
/// lines go to stderr via the shared log formatter.
pub fn printBanner(w: *std.Io.Writer, opts: BannerOptions) void {
    const color = opts.color;

    w.writeAll("\n") catch return;

    // Brand line: 🐯 TigerClaw <version> (<commit>) — <tagline>
    const tagline = currentTagline();
    if (color) {
        w.print("{s}🐯 TigerClaw{s} {s}{s}{s} {s}({s}){s} {s}—{s} {s}{s}{s}{s}\n", .{
            ORANGE,       RESET,
            BOLD,         WHITE_BRIGHT,
            opts.version, RESET ++ GREY,
            opts.commit,  RESET,
            GREY,         RESET,
            DIM,          ITALIC,
            tagline,      RESET,
        }) catch return;
    } else {
        w.print("TigerClaw {s} ({s}) -- {s}\n", .{ opts.version, opts.commit, tagline }) catch return;
    }

    // Clack-style separator between the brand header and the
    // timestamped subsystem log lines. Keeps the eye from
    // glueing the brand line onto the first [gateway] entry.
    if (color) {
        w.writeAll(GREY ++ "│" ++ RESET ++ "\n") catch return;
        w.writeAll(GREY ++ "◇" ++ RESET ++ "\n") catch return;
    } else {
        w.writeAll("│\n◇\n") catch return;
    }

    // agent model line (when known)
    if (opts.agent_model) |model| {
        writeLine(w, color, .info, "agent model: {s}{s}{s}", .{
            if (color) WHITE_BRIGHT else "",
            model,
            if (color) RESET else "",
        });
    }

    // listening line
    writeLine(w, color, .info, "listening on {s}{s}http://{s}:{d}{s}", .{
        if (color) BOLD else "",
        if (color) GREEN else "",
        opts.host,
        opts.port,
        if (color) RESET else "",
    });

    // ready line with agent list
    writeReady(w, color, opts.loaded_agents);

    // verbose banner (only when on)
    if (opts.verbose) {
        writeLine(w, color, .warn, "verbose mode enabled (debug logging active)", .{});
    }

    // Ctrl+C
    writeLine(w, color, .dim, "Ctrl+C to stop", .{});

    w.writeAll("\n") catch return;
    w.flush() catch return;
}

const LineKind = enum { info, warn, dim };

fn writeLine(
    w: *std.Io.Writer,
    color: bool,
    kind: LineKind,
    comptime fmt: []const u8,
    args: anytype,
) void {
    writeTimestamp(w, color);
    if (color) {
        w.writeAll(GREY ++ "[gateway]" ++ RESET ++ " ") catch return;
        switch (kind) {
            .info => {},
            .warn => w.writeAll(BOLD ++ YELLOW) catch return,
            .dim => w.writeAll(DIM) catch return,
        }
        w.print(fmt, args) catch return;
        w.writeAll(RESET ++ "\n") catch return;
    } else {
        w.writeAll("[gateway] ") catch return;
        w.print(fmt, args) catch return;
        w.writeAll("\n") catch return;
    }
}

fn writeReady(w: *std.Io.Writer, color: bool, agents: []const []const u8) void {
    writeTimestamp(w, color);
    if (color) {
        w.writeAll(GREY ++ "[gateway]" ++ RESET ++ " " ++ BOLD ++ GREEN ++ "ready" ++ RESET) catch return;
    } else {
        w.writeAll("[gateway] ready") catch return;
    }

    if (agents.len > 0) {
        w.print(" ({d} agent", .{agents.len}) catch return;
        if (agents.len > 1) w.writeAll("s") catch return;
        w.writeAll(": ") catch return;
        for (agents, 0..) |name, i| {
            if (i > 0) w.writeAll(", ") catch return;
            if (color) w.writeAll(WHITE_BRIGHT) catch return;
            w.writeAll(name) catch return;
            if (color) w.writeAll(RESET) catch return;
        }
        w.writeAll(")") catch return;
    } else {
        w.writeAll(" (0 agents)") catch return;
    }
    w.writeAll("\n") catch return;
}

// ── Tests ────────────────────────────────────────────────────

const testing = std.testing;

test "pickTagline is deterministic and in range" {
    const a = pickTagline(12345);
    const b = pickTagline(12345);
    try testing.expectEqualStrings(a, b);
    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        const t = pickTagline(i);
        try testing.expect(t.len > 0);
    }
}

test "printBanner plain contains brand, version, and listening" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const agents = [_][]const u8{ "tiger", "scout" };
    printBanner(&w, .{
        .version = "0.1.0",
        .commit = "abc123",
        .host = "127.0.0.1",
        .port = 8765,
        .agent_model = "anthropic/sonnet",
        .loaded_agents = &agents,
        .verbose = true,
        .color = false,
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "TigerClaw 0.1.0 (abc123)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "listening on http://127.0.0.1:8765") != null);
    try testing.expect(std.mem.indexOf(u8, out, "agent model: anthropic/sonnet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ready (2 agents: tiger, scout)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "verbose mode enabled") != null);
}

test "printBanner reports 0 agents when list is empty" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    printBanner(&w, .{ .host = "0.0.0.0", .port = 80, .color = false });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "ready (0 agents)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "verbose") == null);
}

test "printBanner with color emits ANSI escape sequences" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    printBanner(&w, .{ .host = "127.0.0.1", .port = 80, .color = true });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}
