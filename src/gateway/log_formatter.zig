//! Custom std.log formatter for the gateway.
//!
//! Wired into `std_options` at the root of the binary so every
//! `std.log.scoped(.gateway).info(...)` call produces a timestamped,
//! levelled, optionally-coloured line on stderr.
//!
//! Format:  HH:MM:SS [gateway:info] message
//!
//! Level gating is a global atomic so `--verbose` can flip debug
//! on at runtime without having to rebuild with a different
//! log_level. Non-gateway scopes fall through to a plain formatter
//! so `std.log` calls outside the gateway still surface.

const std = @import("std");
const builtin = @import("builtin");

// ── ANSI palette ─────────────────────────────────────────────

const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const GREY = "\x1b[90m";
const CYAN = "\x1b[36m";

// ── Runtime state ────────────────────────────────────────────

/// Set to `true` by `--verbose` so `.debug` messages are emitted.
/// Atomic because the sigaction path (and in the future, a hot
/// reload endpoint) may mutate it concurrently with the accept
/// thread reading it in `logFn`.
pub var verbose_enabled: std.atomic.Value(bool) = .init(false);

/// Cached colour decision — set once at `install()` time so every
/// log line doesn't re-run the isatty probe. `--no-color` and
/// `NO_COLOR` honour flip this off up front.
pub var color_enabled: std.atomic.Value(bool) = .init(false);

pub fn setVerbose(on: bool) void {
    verbose_enabled.store(on, .release);
}

pub fn setColor(on: bool) void {
    color_enabled.store(on, .release);
}

// ── std_options hook ─────────────────────────────────────────

/// Drop-in replacement for the default `std.log.defaultLog`. Wire
/// this into `pub const std_options = .{ .logFn = ... }` at the
/// binary root.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Gate `.debug` behind the verbose flag so info is the default
    // floor and debug only fires under `--verbose`.
    if (level == .debug and !verbose_enabled.load(.acquire)) return;

    // Suppress vaxis's `.info` chatter ("kitty keyboard capability
    // detected", etc.). It writes to stderr before the alt-screen
    // takes over, so the user sees a wall of capability lines
    // every TUI launch. Warnings and errors from vaxis still
    // surface — those usually indicate something the user should
    // see (resize panic, render failure). Errors and warns from
    // any scope continue to log at all levels.
    if (scope == .vaxis and level == .info) return;

    // Build the line into a stack buffer. We avoid heap allocation
    // in the log path so logging stays usable under OOM.
    var buf: [4096]u8 = undefined;
    var bw = std.Io.Writer.fixed(&buf);

    const color = color_enabled.load(.acquire);
    writeTimestamp(&bw, color);
    writeScopeAndLevel(&bw, level, scope, color);
    bw.print(format, args) catch return;
    bw.writeAll("\n") catch return;

    // Best-effort write to stderr via the libc file descriptor so
    // we don't need a std.Io handle here.
    const written = bw.buffered();
    writeStderr(written);
}

fn writeStderr(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        // Windows has no std.c.write surface in 0.16; std.debug.print
        // holds a global mutex and is NOT async-signal-safe. For the
        // gateway's cooperative log path this is acceptable; do not
        // call logFn from signal/panic handlers on Windows.
        std.debug.print("{s}", .{bytes});
        return;
    }
    // POSIX: libc write(2) is async-signal-safe and doesn't allocate.
    // Zig 0.16 dropped std.posix.write; we reach for libc directly.
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

fn nowEpochSecs() i64 {
    if (builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

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

fn writeScopeAndLevel(
    w: *std.Io.Writer,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    color: bool,
) void {
    const level_color = comptime switch (level) {
        .debug => DIM,
        .info => GREEN,
        .warn => YELLOW,
        .err => RED,
    };
    const scope_name = comptime @tagName(scope);

    if (color) {
        w.writeAll("[") catch return;
        w.writeAll(CYAN) catch return;
        w.writeAll(scope_name) catch return;
        w.writeAll(RESET) catch return;
        w.writeAll(":") catch return;
        w.writeAll(level_color) catch return;
        w.writeAll(@tagName(level)) catch return;
        w.writeAll(RESET) catch return;
        w.writeAll("] ") catch return;
    } else {
        w.print("[{s}:{s}] ", .{ scope_name, @tagName(level) }) catch return;
    }
}

// ── Tests ────────────────────────────────────────────────────

const testing = std.testing;

test "setVerbose toggles the gate" {
    defer setVerbose(false);
    setVerbose(true);
    try testing.expect(verbose_enabled.load(.acquire));
    setVerbose(false);
    try testing.expect(!verbose_enabled.load(.acquire));
}

test "setColor toggles the gate" {
    defer setColor(false);
    setColor(true);
    try testing.expect(color_enabled.load(.acquire));
    setColor(false);
    try testing.expect(!color_enabled.load(.acquire));
}
