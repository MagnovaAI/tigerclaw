//! vxfw history widget.
//!
//! Renders a bottom-anchored, scrollable list of chat lines. Each
//! line is a speaker glyph + styled body with per-byte markdown
//! spans. The widget borrows a `[]const Line` from the owner
//! (RootWidget); it doesn't manage history's lifecycle.
//!
//! Rendering is two-pass:
//!   1. Walk the lines and emit one `LogicalRow` per wrapped /
//!      hard-broken row (the "buffer").
//!   2. Slice a height-tall viewport out of the buffer, anchored
//!      by `scroll_offset`, and paint it into the surface.
//!
//! `scroll_offset` is the number of rows the user has scrolled up
//! from the live tail. 0 = newest content sits at the bottom row;
//! larger values reveal older content above. The owner reset to
//! 0 on every new chunk so streaming output is always visible.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");
const md = @import("../md.zig");
const user_message = @import("user_message.zig");

const History = @This();

// --- state (borrowed) ---
lines: []const tui.Line,
/// Rows of scrollback above the live tail. 0 = bottom (newest at
/// the last row); larger values shift the viewport upward into
/// older content. Clamped at draw time.
scroll_offset: u32 = 0,

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

/// One physical row of the rendered buffer. `bytes` and the
/// associated metadata point into the source `Line.text`; `spans`
/// is the same span slice the source line carries (or null), with
/// the row's `bytes_start_in_line` offset to feed `pickStyle`.
///
/// `kind = .blank` rows occupy vertical space (used to gap role
/// transitions) but paint nothing -- they have no source line.
/// `kind = .user_pad_top` paints `▄` (lower-half block) full-width
/// in the panel tint -- the bottom half of the row is tinted, the
/// top half is the terminal default. `kind = .user_pad_bot` mirrors
/// with `▀`. Together with a solid-tint content row in between,
/// they form the half-block centred-prompt look.
const LogicalRow = struct {
    kind: Kind,
    line_idx: u32 = 0,
    /// Offset within `line.text.items` where this row starts.
    bytes_offset: u32 = 0,
    /// Length of this row's bytes within `line.text.items`.
    bytes_len: u32 = 0,
    /// True only for the line's first physical row -- the row that
    /// gets the speaker glyph painted at column 0.
    is_first: bool = false,

    pub const Kind = enum { content, blank, user_pad_top, user_pad_bot };
};

pub fn draw(self: *const History, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width == 0 or height == 0 or self.lines.len == 0) return surface;

    // Pass 1: flatten the history into a list of physical rows. We
    // allocate into the draw context's arena so the slice's lifetime
    // ends with the frame.
    var rows: std.ArrayList(LogicalRow) = .empty;
    // No deinit -- arena reclaims on frame end.

    // Insert a blank row before every speaker change (and before
    // every fresh user/agent turn following a tool block) so the
    // chat doesn't read as one dense wall. Tool lines stay tight
    // under the agent line they belong to.
    var prev_role: ?tui.Line.Role = null;
    for (self.lines, 0..) |line, idx| {
        // Inter-role gap. User lines bracket themselves with
        // half-block pad rows below, so they don't take a regular
        // gap row -- the `▄` above the content already separates
        // them visually from whatever came before.
        if (line.role == .user) {
            try rows.append(ctx.arena, .{ .kind = .user_pad_top });
        } else if (shouldGapBefore(prev_role, line.role)) {
            try rows.append(ctx.arena, .{ .kind = .blank });
        }
        prev_role = line.role;

        const prefix_cols = measureCols(prefixFor(&line));
        const avail: usize = if (width > prefix_cols) width - prefix_cols else 1;

        // Per-line cap mirrors the old renderer: a runaway tool
        // dump shouldn't be able to fill the whole buffer with one
        // entry. The remainder is silently truncated.
        var rows_in_line: u32 = 0;
        const max_rows_per_line: u32 = 32;

        var seg_start: usize = 0;
        while (seg_start <= line.text.items.len and rows_in_line < max_rows_per_line) {
            const nl_pos = std.mem.indexOfScalarPos(u8, line.text.items, seg_start, '\n');
            const seg_end = nl_pos orelse line.text.items.len;
            const segment = line.text.items[seg_start..seg_end];

            // Empty segment (a literal blank line) still occupies
            // one row.
            if (segment.len == 0) {
                try rows.append(ctx.arena, .{
                    .kind = .content,
                    .line_idx = @intCast(idx),
                    .bytes_offset = @intCast(seg_start),
                    .bytes_len = 0,
                    .is_first = (rows_in_line == 0),
                });
                rows_in_line += 1;
            } else {
                // Soft-wrap by display columns.
                var off: usize = 0;
                while (off < segment.len and rows_in_line < max_rows_per_line) {
                    const taken = takeCols(segment[off..], avail);
                    const take = if (taken.bytes == 0) safeUtf8Take(segment[off..], 1) else taken.bytes;
                    if (take == 0) break;
                    try rows.append(ctx.arena, .{
                        .kind = .content,
                        .line_idx = @intCast(idx),
                        .bytes_offset = @intCast(seg_start + off),
                        .bytes_len = @intCast(take),
                        .is_first = (rows_in_line == 0),
                    });
                    rows_in_line += 1;
                    off += take;
                }
            }

            // Move past the newline if any. When we ran out at the
            // end of the buffer (no newline) this exits the loop.
            if (nl_pos) |p| {
                seg_start = p + 1;
            } else {
                break;
            }
        }

        // Edge case: a line with empty text and no newline still
        // wants a row so the speaker glyph is visible.
        if (rows_in_line == 0) {
            try rows.append(ctx.arena, .{
                .kind = .content,
                .line_idx = @intCast(idx),
                .bytes_offset = 0,
                .bytes_len = 0,
                .is_first = true,
            });
        }

        // Trailing half-block: closes the user-message tint band.
        if (line.role == .user) {
            try rows.append(ctx.arena, .{ .kind = .user_pad_bot });
        }
    }

    if (rows.items.len == 0) return surface;

    const total_rows: u32 = @intCast(rows.items.len);

    // Compute the viewport over the rows buffer.
    //
    // viewport_top = first row of the buffer that lands on screen.
    // When the buffer fits entirely in the pane, we anchor to the
    // bottom (newer content at the bottom row, older above) -- this
    // matches the user's prior expectation of a chat log.
    //
    // When the buffer is larger than the pane, scroll_offset slides
    // the window upward by N rows. Clamped so the oldest row is
    // always at least partially visible.
    const max_offset: u32 = if (total_rows > height) total_rows - height else 0;
    const offset: u32 = if (self.scroll_offset > max_offset) max_offset else self.scroll_offset;

    const viewport_bottom: u32 = total_rows - offset;
    const viewport_top: u32 = if (viewport_bottom > height) viewport_bottom - height else 0;

    // First screen row that holds content. When total_rows < height
    // we leave the top of the pane blank so the newest line still
    // sits at the bottom row.
    const screen_first_row: u32 = if (viewport_bottom < height) height - viewport_bottom else 0;

    // Pass 2: paint each visible row.
    var screen_row: u16 = @intCast(screen_first_row);
    var i: u32 = viewport_top;
    while (i < viewport_bottom and screen_row < height) : (i += 1) {
        const r = rows.items[i];
        // Blank rows just consume vertical space — the surface is
        // already zero-initialized so we don't need to paint
        // anything to leave them empty.
        if (r.kind == .blank) {
            screen_row += 1;
            continue;
        }
        // Half-block pad rows -- delegated to the user_message
        // widget so the band's look (half-block glyphs, tint,
        // inset) lives in one place.
        if (r.kind == .user_pad_top or r.kind == .user_pad_bot) {
            user_message.paintRow(
                ctx,
                surface,
                screen_row,
                if (r.kind == .user_pad_top) .top else .bot,
                "",
                0,
                null,
                false,
                0,
                0,
            );
            screen_row += 1;
            continue;
        }
        const line = &self.lines[r.line_idx];

        // User-message content rows are owned by the user_message
        // widget so the band's look (tinted bg, prompt glyph,
        // body text style) lives in one module.
        if (line.role == .user) {
            const body_user = line.text.items[r.bytes_offset..][0..r.bytes_len];
            user_message.paintRow(
                ctx,
                surface,
                screen_row,
                .content,
                body_user,
                r.bytes_offset,
                line.spans,
                r.is_first,
                0,
                0,
            );
            screen_row += 1;
            continue;
        }

        const base_style = styleFor(line.role);
        const parts = splitPrefix(line);
        const prefix_cols = measureCols(parts.limb) + measureCols(parts.bullet);

        // First physical row of the line gets the speaker glyph.
        // Continuation rows indent under it so wrapped text aligns
        // visually with the body of the first row. Limb is dimmed
        // (it's structural scaffolding); the bullet picks up the
        // status color so tool rows can show green/red/white.
        if (r.is_first) {
            writeGraphemes(ctx, surface, 0, screen_row, parts.limb, tui.palette.tool);
            const bullet_col: u16 = @intCast(measureCols(parts.limb));
            writeGraphemes(ctx, surface, bullet_col, screen_row, parts.bullet, prefixStyleFor(line));
        }

        const body = line.text.items[r.bytes_offset..][0..r.bytes_len];
        paintRow(
            ctx,
            surface,
            screen_row,
            @intCast(prefix_cols),
            body,
            r.bytes_offset,
            base_style,
            line.spans,
        );

        screen_row += 1;
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

/// Decide whether to insert a one-row gap before a line of `cur`
/// that follows a line of `prev`. Tool lines stay tight under the
/// agent line they belong to. User lines bracket themselves with
/// half-block pad rows, so they don't need a regular gap on top of
/// that -- the `▄` row already separates them visually from
/// whatever came before. Every other transition gets one row of
/// breathing room.
fn shouldGapBefore(prev: ?tui.Line.Role, cur: tui.Line.Role) bool {
    const p = prev orelse return false; // first line: no leading gap
    if (p == cur) return false;
    if (cur == .tool) return false; // tool clings to the line above
    if (cur == .user) return false; // user_pad_top already separates
    if (p == .user) return false; // user_pad_bot already separates
    return true;
}

/// Sum the wrapped row count of every line as it would render at
/// `width`, including the inter-role gap rows the draw pass injects.
/// Used for max-scroll computations and tests; mirrors the per-line
/// capping the draw loop applies.
pub fn totalRowsFor(lines: []const tui.Line, width: u16) u32 {
    if (width == 0) return 0;
    var total: u32 = 0;
    var prev_role: ?tui.Line.Role = null;
    for (lines) |*line| {
        if (line.role == .user) {
            total += 2; // half-block pads above and below the content
        } else if (shouldGapBefore(prev_role, line.role)) {
            total += 1;
        }
        prev_role = line.role;

        const prefix = prefixFor(line);
        const prefix_cols = measureCols(prefix);
        const avail: usize = if (width > prefix_cols) width - prefix_cols else 1;

        var rows_needed: u32 = 0;
        var seg_it = std.mem.splitScalar(u8, line.text.items, '\n');
        while (seg_it.next()) |seg| {
            const seg_cols = measureCols(seg);
            const seg_rows: u32 = if (seg_cols == 0) 1 else @intCast((seg_cols + avail - 1) / avail);
            rows_needed += seg_rows;
        }
        if (rows_needed == 0) rows_needed = 1;
        if (rows_needed > 32) rows_needed = 32;
        total += rows_needed;
    }
    return total;
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

fn prefixFor(line: *const tui.Line) []const u8 {
    // Single-cell ASCII-adjacent glyphs only -- no wide emoji,
    // no braille spinners inline. The `›` for user mirrors the
    // input box's prompt so a sent message visually echoes the
    // panel it was typed into. Tool rows that came through the
    // structured pipeline (tool_name set) get a status bullet —
    // the legacy `⎿ ` continuation glyph is reserved for plain
    // tool result lines that don't carry their own header.
    return switch (line.role) {
        .user => "› ",
        .agent => "⏺ ",
        .system => "∙ ",
        // Tool rows: the visible prefix is the tree limb plus the
        // status-colored bullet. Limb selection drives sibling
        // grouping — `├─` for mid, `└─` for last (or unfinished —
        // we only know "last" once the turn ends). `tool_name`
        // null means this is a tool-result continuation row, not
        // a header — those get the legacy fallback glyph.
        .tool => if (line.tool_name != null)
            (if (line.tool_is_last_in_turn) "└─ ● " else "├─ ● ")
        else
            "⎿ ",
    };
}

/// Split a tool row's prefix into its limb (`├─ ` / `└─ `) and
/// bullet (`● `) so the two can be painted with different styles.
/// For non-tool rows or continuation rows the limb is empty and
/// the whole prefix is the bullet, matching the legacy behavior.
fn splitPrefix(line: *const tui.Line) struct { limb: []const u8, bullet: []const u8 } {
    if (line.role == .tool and line.tool_name != null) {
        const limb: []const u8 = if (line.tool_is_last_in_turn) "└─ " else "├─ ";
        return .{ .limb = limb, .bullet = "● " };
    }
    return .{ .limb = "", .bullet = prefixFor(line) };
}

fn styleFor(role: tui.Line.Role) vaxis.Style {
    return switch (role) {
        // User echo gets the input panel's bg tint + cream fg, so a
        // sent message looks like a frozen copy of the input row.
        // Bold keeps the prefix prompt glyph visually weighted.
        .user => tui.palette.input_text,
        .agent => tui.palette.agent,
        .system => tui.palette.system,
        .tool => tui.palette.tool,
    };
}

/// Style for the leading prefix glyph. Tool rows pick a status
/// color so the user can see at a glance which calls succeeded.
/// Other roles reuse the body style.
fn prefixStyleFor(line: *const tui.Line) vaxis.Style {
    if (line.role == .tool and line.tool_name != null) {
        return switch (line.tool_status) {
            .running => tui.palette.tool_bullet_running,
            .ok => tui.palette.tool_bullet_ok,
            .err => tui.palette.tool_bullet_err,
        };
    }
    return styleFor(line.role);
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

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "totalRowsFor: single short agent line counts as one row" {
    const allocator = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "hello");
    const lines = [_]tui.Line{.{ .role = .agent, .text = text }};
    try testing.expectEqual(@as(u32, 1), totalRowsFor(&lines, 80));
}

test "totalRowsFor: wraps long agent line by available columns" {
    const allocator = testing.allocator;
    // 200 cols of content at width 50 (less the 2-col agent prefix
    // = 48 avail) wraps to 5 rows: ceil(200 / 48).
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 200);
    const lines = [_]tui.Line{.{ .role = .agent, .text = text }};
    try testing.expectEqual(@as(u32, 5), totalRowsFor(&lines, 50));
}

test "totalRowsFor: user line gets half-block pads above and below" {
    const allocator = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "hi");
    const lines = [_]tui.Line{.{ .role = .user, .text = text }};
    // 1 top pad + 1 content + 1 bottom pad = 3.
    try testing.expectEqual(@as(u32, 3), totalRowsFor(&lines, 80));
}

test "totalRowsFor: hard \\n breaks count distinct rows" {
    const allocator = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "a\nb\nc");
    const lines = [_]tui.Line{.{ .role = .agent, .text = text }};
    try testing.expectEqual(@as(u32, 3), totalRowsFor(&lines, 80));
}

test "totalRowsFor: empty list is zero" {
    try testing.expectEqual(@as(u32, 0), totalRowsFor(&.{}, 80));
}

test "totalRowsFor: per-line cap at 32 rows" {
    const allocator = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 10_000);
    const lines = [_]tui.Line{.{ .role = .agent, .text = text }};
    try testing.expectEqual(@as(u32, 32), totalRowsFor(&lines, 21));
}
