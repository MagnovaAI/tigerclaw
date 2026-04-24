//! vxfw history widget.
//!
//! Renders a bottom-anchored list of chat lines — each one a
//! speaker glyph + styled body with per-byte markdown spans. The
//! widget borrows a `[]const Line` from the owner (RootWidget);
//! it doesn't manage the history's lifecycle.
//!
//! Behavior preserved from the hand-rolled drawHistory:
//!   * Bottom-up rendering (newest line at the pane's bottom row).
//!   * Column-aware wrapping via vaxis's grapheme-width table.
//!   * Hard-break on embedded `\n` so multi-line tool output
//!     paints in the correct order.
//!   * Role prefix at the first row of each line; continuation
//!     rows indent under it.
//!   * Markdown spans overlaid on the line's base style.
//!
//! Intentionally not preserved: the old bits of math that mixed
//! bytes with columns. Everything here is measured in display
//! cells from the start.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");
const md = @import("../md.zig");

const History = @This();

// --- state (borrowed) ---
lines: []const tui.Line,

pub fn widget(self: *const History) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const History = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const History, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width == 0 or height == 0 or self.lines.len == 0) return surface;

    // Walk bottom-up. `row_cursor` is the next row to paint into,
    // starting from the last row of the pane. For each history
    // entry we compute how many rows it needs, then paint top-down
    // starting at `row_cursor - rows_needed + 1`.
    var row_cursor: i32 = @as(i32, @intCast(height)) - 1;
    var i: usize = self.lines.len;
    while (i > 0 and row_cursor >= 0) {
        i -= 1;
        const line = self.lines[i];
        const prefix = prefixFor(line.role);
        const prefix_cols = measureCols(prefix);
        const avail = if (width > prefix_cols) width - prefix_cols else 1;

        // Rows needed, counting embedded newlines as hard breaks.
        var rows_needed: usize = 0;
        var seg_it = std.mem.splitScalar(u8, line.text.items, '\n');
        while (seg_it.next()) |seg| {
            const seg_cols = measureCols(seg);
            const seg_rows: usize = if (seg_cols == 0) 1 else (seg_cols + avail - 1) / avail;
            rows_needed += seg_rows;
        }
        if (rows_needed == 0) rows_needed = 1;
        if (rows_needed > 32) rows_needed = 32;

        var remaining = line.text.items;
        var start_row = row_cursor - @as(i32, @intCast(rows_needed - 1));

        // Off-screen top: skip the appropriate number of leading
        // display cols so what's visible starts at row 0.
        if (start_row < 0) {
            const drop = @as(usize, @intCast(-start_row));
            if (drop >= rows_needed) {
                row_cursor -= @intCast(rows_needed);
                continue;
            }
            var cols_to_skip: usize = drop * avail;
            while (cols_to_skip > 0 and remaining.len > 0) {
                const taken = takeCols(remaining, cols_to_skip);
                if (taken.bytes == 0) break;
                remaining = remaining[taken.bytes..];
                cols_to_skip -= taken.cols;
                if (taken.cols == 0) break;
            }
            rows_needed -= drop;
            start_row = 0;
        }

        const base_style = styleFor(line.role);

        // Paint the prefix at the first row of the line.
        writeGraphemes(ctx, surface, 0, @intCast(start_row), prefix, base_style);

        // Paint the body, segment by segment (hard-wrap on \n),
        // then soft-wrap on `avail` columns.
        const total_len = line.text.items.len;
        const span_offset_start: usize = total_len - remaining.len;

        var row = start_row;
        var col_offset: usize = prefix_cols;
        var cursor_abs: usize = span_offset_start;
        while (remaining.len > 0 and row < height) {
            const nl_pos: ?usize = std.mem.indexOfScalar(u8, remaining, '\n');
            const limit = if (nl_pos) |p| p else remaining.len;

            const taken = takeCols(remaining[0..limit], avail);
            const take = if (taken.bytes == 0) safeUtf8Take(remaining[0..limit], 1) else taken.bytes;

            paintRow(
                ctx,
                surface,
                @intCast(row),
                @intCast(col_offset),
                remaining[0..take],
                cursor_abs,
                base_style,
                line.spans,
            );

            remaining = remaining[take..];
            cursor_abs += take;
            if (remaining.len > 0 and remaining[0] == '\n') {
                remaining = remaining[1..];
                cursor_abs += 1;
            }
            row += 1;
            col_offset = prefix_cols;
        }

        row_cursor -= @intCast(rows_needed);
    }

    return surface;
}

/// Paint a slice of bytes at (row, col_start), applying the
/// innermost covering markdown span's style on top of `base`.
/// Walks codepoint by codepoint (via ctx.graphemeIterator) so
/// multi-byte chars advance the column by their display width.
fn paintRow(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    row: u16,
    col_start: u16,
    bytes: []const u8,
    bytes_start_in_line: usize,
    base_style: vaxis.Style,
    spans: ?[]md.Span,
) void {
    var col = col_start;
    var abs = bytes_start_in_line;
    var iter = ctx.graphemeIterator(bytes);
    while (iter.next()) |g| {
        if (col >= surface.size.width) break;
        const grapheme = g.bytes(bytes);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        const style = pickStyle(abs, base_style, spans);
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
        abs += grapheme.len;
    }
}

/// Walk `bytes` codepoint by codepoint accumulating display
/// columns via vaxis's `gwidth`. Stop before exceeding `max_cols`.
fn takeCols(bytes: []const u8, max_cols: usize) struct { bytes: usize, cols: usize } {
    if (max_cols == 0) return .{ .bytes = 0, .cols = 0 };
    var i: usize = 0;
    var cols: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const seq_len: usize = if (b < 0x80)
            1
        else if ((b & 0b1110_0000) == 0b1100_0000)
            2
        else if ((b & 0b1111_0000) == 0b1110_0000)
            3
        else if ((b & 0b1111_1000) == 0b1111_0000)
            4
        else
            1;
        if (i + seq_len > bytes.len) break;
        const w: usize = @intCast(vaxis.gwidth.gwidth(bytes[i .. i + seq_len], .unicode));
        if (cols + w > max_cols) break;
        cols += w;
        i += seq_len;
    }
    return .{ .bytes = i, .cols = cols };
}

fn measureCols(bytes: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
}

fn safeUtf8Take(bytes: []const u8, max: usize) usize {
    if (max >= bytes.len) return bytes.len;
    if (max == 0) return 0;
    var n = max;
    while (n > 0 and (bytes[n] & 0b1100_0000) == 0b1000_0000) : (n -= 1) {}
    return n;
}

fn writeGraphemes(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
) void {
    if (text.len == 0) return;
    var col = start_col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |g| {
        if (col >= surface.size.width) break;
        const grapheme = g.bytes(text);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
    }
}

fn prefixFor(role: tui.Line.Role) []const u8 {
    // Line glyph scheme:
    //   ⏺  every action/utterance (agent + tool)
    //   ❯  the user's input echo
    //   ∙  system notices
    // Single-cell ASCII-adjacent glyphs only — no wide emoji,
    // no braille spinners inline. Animation lives in the
    // dedicated thinking row above the input.
    return switch (role) {
        .user => "❯ ",
        .agent => "⏺ ",
        .system => "∙ ",
        .tool => "⎿ ",
    };
}

fn styleFor(role: tui.Line.Role) vaxis.Style {
    return switch (role) {
        .user => tui.palette.user,
        .agent => tui.palette.agent,
        .system => tui.palette.system,
        .tool => tui.palette.tool,
    };
}

/// Pick the style for byte `abs` in the full line: innermost
/// covering span's style overlaid on `base`, or `base` alone.
fn pickStyle(abs: usize, base: vaxis.Style, spans: ?[]md.Span) vaxis.Style {
    var s = base;
    if (spans) |sp_slice| {
        for (sp_slice) |sp| {
            if (abs >= sp.start and abs < sp.start + sp.len) {
                s = tui.palette.mdStyle(s, sp.style);
            }
        }
    }
    return s;
}
