//! Single-row footer status bar.
//!
//! Layout (pipe-separated cells, left-aligned, fills the row with
//! the status background tint):
//!
//!   agent │ model │ <used>/<max> [bar] N% │ gateway: on │ locked: a/b/c
//!
//! The context cell collapses to just `<used>` when the model's
//! max context is unknown. The sandbox cell renders as `unlocked`
//! when the runner is unsandboxed and `locked: <tail>` when it
//! has a path; the path is truncated to its last three segments
//! so the bar stays readable on narrow terminals.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const StatusBar = @This();

// --- state (borrowed from RootWidget per frame) ---
agent_name: []const u8 = "tiger",
model: []const u8 = "",
/// Tokens currently in the context window (input + cache buckets
/// from the most recent ChatResponse). `0` pre-first-turn.
ctx_used: u64 = 0,
/// Model's max context window in tokens. `0` when unknown — the
/// bar then renders just the used count, no bar, no percent.
ctx_max: u64 = 0,
gateway_on: bool = false,
turn_stopping: bool = false,
/// Sandbox state. `unlocked` shows just the word; `locked` shows
/// `locked: <last-3-path-segments>`.
sandbox_locked: bool = false,
sandbox_path: []const u8 = "",

pub fn widget(self: *const StatusBar) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const StatusBar = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const StatusBar, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = 1 },
    );
    if (width == 0) return surface;

    // Paint the bg tint across the row first.
    const blank = tui.palette.status_blank;
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        surface.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = blank });
    }

    const sep_style = tui.palette.status_label;
    const value_style = tui.palette.status_value;
    const ok_style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 0x4A, 0xC8, 0x76 } },
        .bg = value_style.bg,
        .bold = true,
    };
    const off_style: vaxis.Style = .{
        .fg = .{ .rgb = .{ 0xD9, 0x4F, 0x4F } },
        .bg = value_style.bg,
        .bold = true,
    };
    const caution_style = tui.palette.status_caution;

    col = 1;

    // 1. agent
    col = writeText(ctx, surface, col, self.agent_name, value_style, width);
    col = writeSep(ctx, surface, col, sep_style, width);

    // 2. model
    if (self.model.len > 0) {
        col = writeText(ctx, surface, col, self.model, value_style, width);
        col = writeSep(ctx, surface, col, sep_style, width);
    }

    // 3. context window: <used>/<max> [bar] N%
    //
    // Vaxis cells hold *borrowed* grapheme slices for the lifetime
    // of the frame; stack-local format buffers go out of scope when
    // `draw` returns and the renderer would then dereference dead
    // memory. Allocate every formatted slice into the draw arena
    // (lives until the frame is painted) so the cells stay valid.
    const used_str = formatTokensArena(ctx.arena, self.ctx_used) catch "?";
    col = writeText(ctx, surface, col, used_str, value_style, width);

    if (self.ctx_max > 0) {
        col = writeText(ctx, surface, col, "/", sep_style, width);
        const max_str = formatTokensArena(ctx.arena, self.ctx_max) catch "?";
        col = writeText(ctx, surface, col, max_str, value_style, width);

        const pct: u8 = pctOf(self.ctx_used, self.ctx_max);
        const bar_style: vaxis.Style = .{
            .fg = ctxBarColor(pct),
            .bg = value_style.bg,
        };
        col = writeText(ctx, surface, col, " [", sep_style, width);
        const bar = ctxBarArena(ctx.arena, pct) catch "..........";
        col = writeText(ctx, surface, col, bar, bar_style, width);
        col = writeText(ctx, surface, col, "] ", sep_style, width);

        const pct_str = std.fmt.allocPrint(ctx.arena, "{d}%", .{pct}) catch "?";
        col = writeText(ctx, surface, col, pct_str, value_style, width);
    }
    col = writeSep(ctx, surface, col, sep_style, width);

    // 4. gateway: on/off
    col = writeText(ctx, surface, col, "gateway: ", sep_style, width);
    if (self.gateway_on) {
        col = writeText(ctx, surface, col, "on", ok_style, width);
    } else {
        col = writeText(ctx, surface, col, "off", off_style, width);
    }
    col = writeSep(ctx, surface, col, sep_style, width);

    // 5. turn state: only shown when cancel is actively in flight.
    if (self.turn_stopping) {
        col = writeText(ctx, surface, col, "turn: ", sep_style, width);
        col = writeText(ctx, surface, col, "stopping", caution_style, width);
        col = writeSep(ctx, surface, col, sep_style, width);
    }

    // 6. sandbox: unlocked or `locked: tail`
    if (self.sandbox_locked) {
        col = writeText(ctx, surface, col, "locked: ", caution_style, width);
        const tail = lastNSegments(self.sandbox_path, 3);
        col = writeText(ctx, surface, col, tail, caution_style, width);
    } else {
        col = writeText(ctx, surface, col, "unlocked", value_style, width);
    }

    return surface;
}

/// Write `text` starting at `col`, return the next free column.
/// Stops at `max_col` and at the row's right edge.
fn writeText(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    text: []const u8,
    style: vaxis.Style,
    max_col: u16,
) u16 {
    if (text.len == 0) return start_col;
    var col = start_col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |g| {
        if (col >= max_col) break;
        const grapheme = g.bytes(text);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        if (col + w > max_col) break;
        surface.writeCell(col, 0, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
    }
    return col;
}

/// `" | "` separator. ASCII pipe so it renders cleanly in every
/// terminal font; the `│` (U+2502) box-drawing version sometimes
/// falls back to a replacement glyph in narrow fonts.
fn writeSep(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    col: u16,
    style: vaxis.Style,
    max_col: u16,
) u16 {
    return writeText(ctx, surface, col, " | ", style, max_col);
}

/// `1234`  → `1.2k`,  `1_500_000` → `1.5m`. Sub-1k stays as-is.
/// Slice is borrowed from `buf`; for cells held by vaxis across
/// frame paints, prefer `formatTokensArena`.
fn formatTokens(buf: []u8, n: u64) []const u8 {
    if (n < 1000) {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    }
    if (n < 1_000_000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}k", .{k}) catch "?";
    }
    const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
    return std.fmt.bufPrint(buf, "{d:.1}m", .{m}) catch "?";
}

/// Arena-backed equivalent. Returned slice lives for the arena's
/// lifetime, which the draw context guarantees through frame end.
fn formatTokensArena(arena: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1000) {
        return std.fmt.allocPrint(arena, "{d}", .{n});
    }
    if (n < 1_000_000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.allocPrint(arena, "{d:.1}k", .{k});
    }
    const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
    return std.fmt.allocPrint(arena, "{d:.1}m", .{m});
}

fn pctOf(used: u64, max: u64) u8 {
    if (max == 0) return 0;
    const r = (used * 100) / max;
    return if (r > 100) 100 else @intCast(r);
}

/// 10-cell block bar, filled proportionally to `pct` (0..100).
/// Slice is borrowed from `buf`; cells held across frame paints
/// must use `ctxBarArena` instead.
fn ctxBar(buf: *[10]u8, pct: u8) []const u8 {
    const filled: usize = (@as(usize, pct) * 10 + 50) / 100;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        buf[i] = if (i < filled) '#' else '.';
    }
    return buf[0..10];
}

/// Arena-backed bar so the slice survives the frame.
fn ctxBarArena(arena: std.mem.Allocator, pct: u8) ![]const u8 {
    const buf = try arena.alloc(u8, 10);
    const filled: usize = (@as(usize, pct) * 10 + 50) / 100;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        buf[i] = if (i < filled) '#' else '.';
    }
    return buf;
}

/// Color-grade the context bar: green under 60%, amber 60–85%,
/// red above 85%. Matches the hermes ramp.
fn ctxBarColor(pct: u8) vaxis.Color {
    if (pct < 60) return .{ .rgb = .{ 0x4A, 0xC8, 0x76 } };
    if (pct < 85) return .{ .rgb = .{ 0xE7, 0xC0, 0x82 } };
    return .{ .rgb = .{ 0xD9, 0x4F, 0x4F } };
}

/// Return the last `n` segments of a slash-separated path. Joins
/// them back with `/` (no leading slash). Empty path → "".
fn lastNSegments(path: []const u8, n: usize) []const u8 {
    if (path.len == 0 or n == 0) return "";
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;

    var segs: usize = 0;
    var i: usize = trimmed.len;
    while (i > 0) : (i -= 1) {
        if (trimmed[i - 1] == '/') {
            segs += 1;
            if (segs == n) return trimmed[i..];
        }
    }
    return trimmed;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "formatTokens: scales by magnitude" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", formatTokens(&buf, 0));
    try testing.expectEqualStrings("999", formatTokens(&buf, 999));
    try testing.expectEqualStrings("1.0k", formatTokens(&buf, 1000));
    try testing.expectEqualStrings("55.2k", formatTokens(&buf, 55_200));
    try testing.expectEqualStrings("1.0m", formatTokens(&buf, 1_000_000));
}

test "pctOf: clamps at 100" {
    try testing.expectEqual(@as(u8, 0), pctOf(0, 1000));
    try testing.expectEqual(@as(u8, 50), pctOf(500, 1000));
    try testing.expectEqual(@as(u8, 100), pctOf(2000, 1000));
    try testing.expectEqual(@as(u8, 0), pctOf(100, 0));
}

test "ctxBar: fills proportionally" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("..........", ctxBar(&buf, 0));
    try testing.expectEqualStrings("#####.....", ctxBar(&buf, 50));
    try testing.expectEqualStrings("##########", ctxBar(&buf, 100));
}

test "lastNSegments: returns last 3 path components" {
    try testing.expectEqualStrings(
        "Workspace/Code/tigerclaw",
        lastNSegments("/Users/omkarbhad/Workspace/Code/tigerclaw", 3),
    );
    try testing.expectEqualStrings(
        "tigerclaw",
        lastNSegments("/Users/omkarbhad/Workspace/Code/tigerclaw", 1),
    );
    try testing.expectEqualStrings(
        "Workspace/Code/tigerclaw",
        lastNSegments("/Users/omkarbhad/Workspace/Code/tigerclaw/", 3),
    );
}

test "lastNSegments: short path returned whole" {
    try testing.expectEqualStrings("foo", lastNSegments("foo", 3));
    try testing.expectEqualStrings("a/b", lastNSegments("a/b", 3));
    try testing.expectEqualStrings("", lastNSegments("", 3));
}
