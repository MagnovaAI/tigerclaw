//! Gateway startup banner in a compact one-liner style.
//!
//! Shape:
//!
//!     🐯 TigerClaw <version> (<commit>) — <tagline>
//!     │
//!     ◇
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
const GREY = "\x1b[90m";

// ── Taglines ─────────────────────────────────────────────────

pub const default_tagline = "Padding into your shell on silent paws. You won't hear a thing until it's done.";

const taglines = [_][]const u8{
    default_tagline,
    "Stripes on. Claws out. What's the target?",
    "I saw that rough edge. It's on the list.",
    "The logs are warming up. Let them talk.",
    "Quiet boot. Sharp teeth. Clean traces.",
    "Your config's weird. I like weird. Let's run it anyway.",
    "You blink, I ship. That's the contract.",
    "One runtime. Many clues. No loose ends.",
    "The shell is open. The trail is fresh.",
    "Roar mode: engaged. Volume: tastefully muted.",
    "Every warning gets a witness now.",
    "Telemetry awake. Gateway listening.",
};

fn nowNanoSeed() u64 {
    if (builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const secs: u64 = @intCast(@max(@as(i64, 0), ts.sec));
    const nsec: u64 = @intCast(@max(@as(i64, 0), ts.nsec));
    return secs *% std.time.ns_per_s +% nsec;
}

pub fn pickTagline(seed: u64) []const u8 {
    return taglines[@intCast(seed % taglines.len)];
}

/// Randomized gateway tagline. Tests stay deterministic by calling
/// pickTagline with a fixed seed.
pub fn currentTagline() []const u8 {
    if (builtin.is_test) return default_tagline;
    var prng = std.Random.DefaultPrng.init(nowNanoSeed());
    return pickTagline(prng.random().int(u64));
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

/// Emit the startup brand banner. `w` is the CLI stdout writer;
/// runtime log lines go to stderr via the shared log formatter.
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
        w.print("🐯 TigerClaw {s} ({s}) — {s}\n", .{ opts.version, opts.commit, tagline }) catch return;
    }

    writeMetaLine(w, opts, color);

    // Clack-style separator between the brand header and gateway logs.
    if (color) {
        w.writeAll(GREY ++ "│" ++ RESET ++ "\n") catch return;
        w.writeAll(GREY ++ "◇" ++ RESET ++ "\n") catch return;
    } else {
        w.writeAll("│\n◇\n") catch return;
    }

    w.flush() catch return;
}

fn writeMetaLine(w: *std.Io.Writer, opts: BannerOptions, color: bool) void {
    if (color) w.writeAll(GREY) catch return;
    w.print("│ gateway http://{s}:{d}", .{ opts.host, opts.port }) catch return;
    if (opts.agent_model) |model| {
        w.print(" · model {s}", .{model}) catch return;
    }
    w.print(" · agents {d}", .{opts.loaded_agents.len}) catch return;
    if (opts.verbose) w.writeAll(" · debug") catch return;
    if (color) w.writeAll(RESET) catch return;
    w.writeAll("\n") catch return;
}

// ── Tests ────────────────────────────────────────────────────

const testing = std.testing;

test "pickTagline is deterministic and in range" {
    const a = pickTagline(12345);
    const b = pickTagline(12345);
    try testing.expectEqualStrings(a, b);
    var i: u64 = 0;
    while (i < taglines.len * 2) : (i += 1) {
        try testing.expect(pickTagline(i).len > 0);
    }
}

test "printBanner plain emits the banner block" {
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
    try testing.expect(std.mem.indexOf(u8, out, "\n🐯 TigerClaw 0.1.0 (abc123) — ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "│ gateway http://127.0.0.1:8765 · model anthropic/sonnet · agents 2 · debug") != null);
    try testing.expect(std.mem.endsWith(u8, out, "│\n◇\n"));
}

test "printBanner does not include runtime log lines" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    printBanner(&w, .{ .host = "0.0.0.0", .port = 80, .color = false });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "[gateway]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "verbose") == null);
}

test "printBanner with color emits ANSI escape sequences" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    printBanner(&w, .{ .host = "127.0.0.1", .port = 80, .color = true });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}
