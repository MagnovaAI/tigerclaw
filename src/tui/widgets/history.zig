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
/// Optional wrap-layout cache owned by the parent widget. When
/// non-null the draw pass reuses pre-computed wrap segments
/// instead of walking the entire transcript through `gwidth` on
/// every frame. Null falls back to the uncached path so unit tests
/// and ad-hoc callers don't have to thread state through.
cache: ?*WrapCache = null,

/// Per-line wrap layout cache. The expensive part of `draw` is
/// converting a line's bytes into a list of physical rows under a
/// given panel width — it walks every grapheme through
/// `vaxis.gwidth` and accumulates display columns. That work is
/// pure of `(text bytes, width, prefix_cols)`, so we memoise it.
///
/// Lifetime: owned by the parent widget (RootWidget). Init once,
/// deinit on shutdown. Entries are reused across frames; a stale
/// entry is detected by comparing `(ptr, len, width, prefix_cols)`
/// against the cached key on lookup.
pub const WrapCache = struct {
    allocator: std.mem.Allocator,
    /// Indexed by line position in `lines`. Resized lazily so the
    /// owner doesn't have to mirror history mutations.
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        /// Identity of the cached input. A miss happens when any
        /// field differs from the live line/width.
        text_ptr: [*]const u8 = undefined,
        text_len: usize = 0,
        width: u16 = 0,
        prefix_cols: u16 = 0,
        valid: bool = false,
        /// Each segment is one wrapped physical row inside one
        /// `\n`-delimited segment of the source text. Stored as
        /// `(byte_offset_in_line, byte_len)` so the draw pass can
        /// slice back into `line.text.items` without re-walking.
        rows: std.ArrayList(Row) = .empty,
    };

    pub const Row = struct {
        bytes_offset: u32,
        bytes_len: u32,
    };

    pub fn init(allocator: std.mem.Allocator) WrapCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WrapCache) void {
        for (self.entries.items) |*e| e.rows.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Drop every entry. Called when the history is rebuilt from
    /// scratch (e.g. session reset) so we don't hand back rows
    /// that point into freed memory.
    pub fn clear(self: *WrapCache) void {
        for (self.entries.items) |*e| {
            e.rows.clearRetainingCapacity();
            e.valid = false;
        }
    }

    /// Look up (or compute) the wrap layout for `line` at `width`
    /// with `prefix_cols` reserved for the speaker pill + glyph.
    /// Returns a borrowed slice of rows valid until the next call
    /// that mutates the same entry (i.e. next miss for this index).
    fn rowsFor(
        self: *WrapCache,
        idx: usize,
        line: *const tui.Line,
        width: u16,
        prefix_cols: u16,
    ) ![]const Row {
        // Grow the entry table so `idx` is addressable. Newly
        // created slots start invalid, forcing a recompute.
        if (idx >= self.entries.items.len) {
            const old_len = self.entries.items.len;
            try self.entries.resize(self.allocator, idx + 1);
            for (self.entries.items[old_len..]) |*e| e.* = .{};
        }
        const entry = &self.entries.items[idx];

        const text = line.text.items;
        const ptr: [*]const u8 = if (text.len == 0) undefined else text.ptr;
        const text_ptr_eq = if (text.len == 0) entry.text_len == 0 else entry.text_ptr == ptr;

        if (entry.valid and
            text_ptr_eq and
            entry.text_len == text.len and
            entry.width == width and
            entry.prefix_cols == prefix_cols)
        {
            return entry.rows.items;
        }

        // Miss — recompute. Reuse the row list's capacity to keep
        // allocator pressure flat under streaming.
        entry.rows.clearRetainingCapacity();
        try wrapLineInto(&entry.rows, self.allocator, text, width, prefix_cols);
        entry.text_ptr = ptr;
        entry.text_len = text.len;
        entry.width = width;
        entry.prefix_cols = prefix_cols;
        entry.valid = true;
        return entry.rows.items;
    }
};

/// Pure wrap routine. Splits `text` into `\n`-delimited segments
/// and soft-wraps each by display columns, capped at 32 rows
/// (mirrors the per-line guard in the draw loop).
fn wrapLineInto(
    out: *std.ArrayList(WrapCache.Row),
    allocator: std.mem.Allocator,
    text: []const u8,
    width: u16,
    prefix_cols: u16,
) !void {
    const max_rows_per_line: u32 = 32;
    const avail: usize = if (width > prefix_cols) width - prefix_cols else 1;

    var rows_in_line: u32 = 0;
    var seg_start: usize = 0;
    while (seg_start <= text.len and rows_in_line < max_rows_per_line) {
        const nl_pos = std.mem.indexOfScalarPos(u8, text, seg_start, '\n');
        const seg_end = nl_pos orelse text.len;
        const segment = text[seg_start..seg_end];

        if (segment.len == 0) {
            try out.append(allocator, .{
                .bytes_offset = @intCast(seg_start),
                .bytes_len = 0,
            });
            rows_in_line += 1;
        } else {
            var off: usize = 0;
            while (off < segment.len and rows_in_line < max_rows_per_line) {
                const taken = takeCols(segment[off..], avail);
                const take = if (taken.bytes == 0) safeUtf8Take(segment[off..], 1) else taken.bytes;
                if (take == 0) break;
                try out.append(allocator, .{
                    .bytes_offset = @intCast(seg_start + off),
                    .bytes_len = @intCast(take),
                });
                rows_in_line += 1;
                off += take;
            }
        }

        if (nl_pos) |p| {
            seg_start = p + 1;
        } else {
            break;
        }
    }

    // Mirror the "empty line still gets one row so the pill paints"
    // edge case the draw loop maintained pre-cache.
    if (rows_in_line == 0) {
        try out.append(allocator, .{ .bytes_offset = 0, .bytes_len = 0 });
    }
}

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
    // Precompute per-line indent. Most rows just use their own
    // pill width (tool rows now stamp the owning agent's name as
    // their speaker, so `pillCols` returns a positive value and
    // the limb (`└─ ●`) lines up after the pill). Tool *result*
    // continuation rows (`tool_name == null`) and any other line
    // without a speaker fall back to inheriting the most recent
    // speaker'd line's pill width so they hang under the body
    // column instead of at column 0. The inherit chain resets on
    // user lines so a fresh turn doesn't pick up indent from the
    // previous agent.
    var indent_pill_cols: std.ArrayList(usize) = .empty;
    try indent_pill_cols.resize(ctx.arena, self.lines.len);
    var carry_pill_w: usize = 0;
    for (self.lines, 0..) |line, idx| {
        const own = pillCols(&line);
        if (own > 0) {
            carry_pill_w = own;
            indent_pill_cols.items[idx] = own;
        } else {
            // System rows live in their own visual class — keep
            // them flush left. Only tool rows inherit.
            indent_pill_cols.items[idx] = if (line.role == .tool) carry_pill_w else 0;
        }
    }

    var prev_role: ?tui.Line.Role = null;
    for (self.lines, 0..) |line, idx| {
        // Banner rows carry width gates so wide and compact wordmarks
        // can coexist in history; the renderer picks whichever fits
        // the live pane. Skip rows whose pane is outside the gated
        // range — no surface allocation, no row buffer entry, no
        // visual trace at all when the gate is closed.
        if (line.role == .banner) {
            if (line.banner_min_width != 0 and width < line.banner_min_width) continue;
            if (line.banner_max_width != 0 and width > line.banner_max_width) continue;
        }
        // Inter-role gap. User lines bracket themselves with
        // half-block pad rows below, so they don't take a regular
        // gap row -- the `▄` above the content already separates
        // them visually from whatever came before.
        if (line.role == .user) {
            try rows.append(ctx.arena, .{ .kind = .user_pad_top, .line_idx = @intCast(idx) });
        } else if (shouldGapBefore(prev_role, line.role)) {
            try rows.append(ctx.arena, .{ .kind = .blank });
        }
        prev_role = line.role;

        const pill_cols = indent_pill_cols.items[idx];
        const prefix_cols = pill_cols + measureCols(prefixFor(&line));

        // Resolve the line's wrap layout. The cached path memoises
        // `(text, width, prefix_cols)` so we don't re-walk every
        // grapheme through `gwidth` on each frame; the fallback
        // path keeps unit tests and ad-hoc callers working without
        // having to wire in a cache instance.
        if (self.cache) |cache_ptr| {
            const cached_rows = try cache_ptr.rowsFor(
                idx,
                &line,
                @intCast(width),
                @intCast(prefix_cols),
            );
            for (cached_rows, 0..) |cr, ri| {
                try rows.append(ctx.arena, .{
                    .kind = .content,
                    .line_idx = @intCast(idx),
                    .bytes_offset = cr.bytes_offset,
                    .bytes_len = cr.bytes_len,
                    .is_first = (ri == 0),
                });
            }
        } else {
            var tmp: std.ArrayList(WrapCache.Row) = .empty;
            defer tmp.deinit(ctx.arena);
            try wrapLineInto(&tmp, ctx.arena, line.text.items, @intCast(width), @intCast(prefix_cols));
            for (tmp.items, 0..) |cr, ri| {
                try rows.append(ctx.arena, .{
                    .kind = .content,
                    .line_idx = @intCast(idx),
                    .bytes_offset = cr.bytes_offset,
                    .bytes_len = cr.bytes_len,
                    .is_first = (ri == 0),
                });
            }
        }

        // Trailing half-block: closes the user-message tint band.
        if (line.role == .user) {
            try rows.append(ctx.arena, .{ .kind = .user_pad_bot, .line_idx = @intCast(idx) });
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
    // sits at the bottom row — that's the chat-log default.
    //
    // Exception: pre-conversation, when the only rows are the
    // startup banner + welcome system line, anchor to the top so
    // the wordmark reads as a header instead of floating at the
    // bottom of an otherwise-empty pane. The first user/agent
    // turn flips us back to bottom-anchored chat-log behaviour.
    const has_chat = blk: {
        for (self.lines) |*l| {
            if (l.role == .user or l.role == .agent or l.role == .tool) break :blk true;
        }
        break :blk false;
    };
    const screen_first_row: u32 = if (viewport_bottom < height and has_chat)
        height - viewport_bottom
    else
        0;

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
            const pad_line = &self.lines[r.line_idx];
            const pad_pill_w: u16 = @intCast(pillCols(pad_line));
            user_message.paintRow(
                ctx,
                surface,
                screen_row,
                if (r.kind == .user_pad_top) .top else .bot,
                "",
                0,
                null,
                false,
                pad_pill_w,
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
            const pill_w = pillCols(line);
            // Paint the speaker pill on the first content row only
            // (subsequent rows are wrapped continuations of the
            // same line). Inset the user band by `pill_w` cols so
            // the tinted shoulder doesn't overlap the pill.
            if (r.is_first) {
                _ = pillPaint(ctx, surface, screen_row, line);
            }
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
                @intCast(pill_w),
                0,
            );
            screen_row += 1;
            continue;
        }

        const base_style = styleFor(line);
        const parts = splitPrefix(line);
        const limb_bullet_cols = measureCols(parts.limb) + measureCols(parts.bullet);
        const pill_w = indent_pill_cols.items[r.line_idx];
        const prefix_cols = pill_w + limb_bullet_cols;

        // First physical row of the line gets the speaker pill +
        // glyph. Continuation rows indent under the same pill width
        // so wrapped body text aligns visually under the first
        // row's body.
        if (r.is_first) {
            _ = pillPaint(ctx, surface, screen_row, line);
            const limb_col: u16 = @intCast(pill_w);
            writeGraphemes(ctx, surface, limb_col, screen_row, parts.limb, tui.palette.tool);
            const bullet_col: u16 = @intCast(pill_w + measureCols(parts.limb));
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
    if (cur == .banner) return false; // banner rows pack tight
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

/// Number of display columns the speaker pill occupies. Format is
/// ` name ` (one tinted pad cell, name, one tinted pad cell) plus
/// one untinted trailing gap, so the cost is `name.len + 3`. Lines
/// without a speaker (system / tool rows) return 0 — they don't
/// get a pill.
fn pillCols(line: *const tui.Line) usize {
    const speaker = line.speaker orelse return 0;
    if (speaker.len == 0) return 0;
    // leading pad + name + trailing pad + outside gap
    return speaker.len + 3;
}

/// Render the speaker pill at column 0 of `row`. No-op when the
/// line has no speaker. The pill is just a tinted block with the
/// name inside — no `[ ]` chrome — so the chat reads as
/// `Omkar  message` rather than `[ Omkar ]  message`.
/// Returns the column where the pill ended.
fn pillPaint(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    row: u16,
    line: *const tui.Line,
) u16 {
    const speaker = line.speaker orelse return 0;
    if (speaker.len == 0) return 0;
    const style = pillStyle(speaker);
    var col: u16 = 0;

    // Leading pad cell — gives the name one tinted column of
    // breathing room on the left so glyphs don't kiss the edge.
    writeGraphemes(ctx, surface, col, row, " ", style);
    col += 1;

    // Name body.
    writeGraphemes(ctx, surface, col, row, speaker, style);
    col += @intCast(measureCols(speaker));

    // Trailing pad cell, same tint.
    writeGraphemes(ctx, surface, col, row, " ", style);
    col += 1;

    // Outside gap — untinted so the pill reads as a separate block
    // from the message body that follows.
    writeGraphemes(ctx, surface, col, row, " ", tui.palette.system);
    col += 1;
    return col;
}

/// Deterministic pill style for `name`. Hashes the name into a
/// fixed 8-color palette so each speaker keeps the same color
/// across launches and lines without any config plumbing.
fn pillStyle(name: []const u8) vaxis.Style {
    const palette = [_]vaxis.Color{
        .{ .rgb = .{ 0xf2, 0x7e, 0x37 } }, // amber
        .{ .rgb = .{ 0x6e, 0xb5, 0xff } }, // sky
        .{ .rgb = .{ 0x9d, 0xe8, 0xa1 } }, // mint
        .{ .rgb = .{ 0xe8, 0x8b, 0xb6 } }, // rose
        .{ .rgb = .{ 0xc6, 0xa1, 0xff } }, // lavender
        .{ .rgb = .{ 0xff, 0xd6, 0x7d } }, // sand
        .{ .rgb = .{ 0x7e, 0xd6, 0xc6 } }, // teal
        .{ .rgb = .{ 0xff, 0xab, 0x70 } }, // peach
    };
    // FNV-1a 32-bit — small, branchless, no allocator.
    var h: u32 = 0x811c9dc5;
    for (name) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    const idx = h % palette.len;
    return .{
        .fg = .{ .rgb = .{ 0x10, 0x10, 0x10 } },
        .bg = palette[idx],
        .bold = true,
    };
}

fn prefixFor(line: *const tui.Line) []const u8 {
    // Single-cell ASCII-adjacent glyphs only -- no wide emoji,
    // no braille spinners inline. The `›` for user mirrors the
    // input box's prompt so a sent message visually echoes the
    // panel it was typed into. Tool rows that came through the
    // structured pipeline (tool_name set) get a status bullet —
    // the legacy `⎿ ` continuation glyph is reserved for plain
    // tool result lines that don't carry their own header.
    //
    // Agent rows used to carry a `⏺ ` prefix; the speaker pill
    // already names the agent (`tiger`, `sage`, …) so the bullet
    // was duplicated visual weight. Dropped to a clean blank.
    return switch (line.role) {
        .user => "› ",
        .agent => "",
        .system => "∙ ",
        // Banner rows scroll along with the rest of the chat and
        // already carry their own painted glyphs (the wordmark
        // shapes, the tigerclaw info line). No prefix.
        .banner => "",
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

/// Six-band gradient for the scrolling tigerclaw wordmark. Index
/// is the 0-based row of the line within the banner block; rows
/// beyond the gradient (e.g. the trailing info line) fall through
/// to the system tint via `styleFor`.
const banner_gradient = [_]vaxis.Style{
    .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .bold = true }, // gold
    .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .bold = true }, // gold
    .{ .fg = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }, .bold = false }, // tiger orange
    .{ .fg = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }, .bold = false }, // tiger orange
    .{ .fg = .{ .rgb = .{ 0xCC, 0x55, 0x00 } }, .bold = false }, // deep ember
    .{ .fg = .{ .rgb = .{ 0xCC, 0x55, 0x00 } }, .bold = false }, // deep ember
};

fn styleFor(line: *const tui.Line) vaxis.Style {
    return switch (line.role) {
        // User echo gets the input panel's bg tint + cream fg, so a
        // sent message looks like a frozen copy of the input row.
        // Bold keeps the prefix prompt glyph visually weighted.
        .user => tui.palette.input_text,
        .agent => tui.palette.agent,
        .system => tui.palette.system,
        .tool => tui.palette.tool,
        // Banner rows: pick the gradient band for this row, or
        // fall through to the system tint when the row index is
        // past the gradient (used by the info/divider rows that
        // follow the wordmark).
        .banner => if (line.banner_row < banner_gradient.len)
            banner_gradient[line.banner_row]
        else
            tui.palette.system,
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
    return styleFor(line);
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
    // 200 cols of content at width 50 (no agent prefix anymore —
    // the speaker pill carries the agent name, the row body gets
    // the full pane width). 200 / 50 = 4 rows.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 200);
    const lines = [_]tui.Line{.{ .role = .agent, .text = text }};
    try testing.expectEqual(@as(u32, 4), totalRowsFor(&lines, 50));
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

// --- WrapCache --------------------------------------------------------------

test "WrapCache: cold lookup populates entry and returns wrap rows" {
    const allocator = testing.allocator;
    var cache = WrapCache.init(allocator);
    defer cache.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 100);
    const line: tui.Line = .{ .role = .agent, .text = text };

    // 100 cols at width 50 with prefix 2 → avail 48 → ceil(100/48)=3.
    const rows = try cache.rowsFor(0, &line, 50, 2);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(u32, 0), rows[0].bytes_offset);
    try testing.expect(cache.entries.items[0].valid);
}

test "WrapCache: identical inputs reuse the cached row slice" {
    const allocator = testing.allocator;
    var cache = WrapCache.init(allocator);
    defer cache.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 100);
    const line: tui.Line = .{ .role = .agent, .text = text };

    const first = try cache.rowsFor(0, &line, 50, 2);
    const first_ptr = first.ptr;
    const first_len = first.len;
    const second = try cache.rowsFor(0, &line, 50, 2);
    // Same backing array, no reallocation, no recompute.
    try testing.expectEqual(first_ptr, second.ptr);
    try testing.expectEqual(first_len, second.len);
}

test "WrapCache: width change invalidates the cached layout" {
    const allocator = testing.allocator;
    var cache = WrapCache.init(allocator);
    defer cache.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 100);
    const line: tui.Line = .{ .role = .agent, .text = text };

    const narrow = try cache.rowsFor(0, &line, 50, 2);
    try testing.expectEqual(@as(usize, 3), narrow.len);
    const wide = try cache.rowsFor(0, &line, 200, 2);
    // 100 cols at width 200 with prefix 2 → avail 198 → 1 row.
    try testing.expectEqual(@as(usize, 1), wide.len);
}

test "WrapCache: text growth invalidates the cached layout" {
    const allocator = testing.allocator;
    var cache = WrapCache.init(allocator);
    defer cache.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendNTimes(allocator, 'x', 50);
    var line: tui.Line = .{ .role = .agent, .text = text };

    const before = try cache.rowsFor(0, &line, 50, 2);
    try testing.expectEqual(@as(usize, 2), before.len);

    // Stream more bytes onto the same line — common during agent
    // replies. Length change must trigger a recompute.
    try text.appendNTimes(allocator, 'x', 50);
    line.text = text;
    const after = try cache.rowsFor(0, &line, 50, 2);
    try testing.expectEqual(@as(usize, 3), after.len);
}

test "WrapCache: clear marks every entry stale without freeing capacity" {
    const allocator = testing.allocator;
    var cache = WrapCache.init(allocator);
    defer cache.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "hello");
    const line: tui.Line = .{ .role = .agent, .text = text };

    _ = try cache.rowsFor(0, &line, 50, 2);
    try testing.expect(cache.entries.items[0].valid);

    cache.clear();
    try testing.expect(!cache.entries.items[0].valid);

    // A subsequent lookup repopulates the same slot.
    _ = try cache.rowsFor(0, &line, 50, 2);
    try testing.expect(cache.entries.items[0].valid);
}
