//! vxfw text input widget.
//!
//! Minimal line editor: one row of editable text framed by a
//! tiger-orange border. Printable keys insert at the cursor;
//! backspace deletes; arrow keys move the cursor; Enter fires
//! the `on_submit` callback with the current buffer contents
//! and clears. No multi-line, no history navigation, no paste
//! bracketing — those land in follow-ups when we actually
//! need them.
//!
//! The widget owns the edit buffer heap-allocated via the
//! provided allocator. Caller calls `deinit` on teardown.
//!
//! A vaxis.widgets.TextInput is available but drags in the
//! whole widget-init-signature churn from 0.15; rolling our
//! own is ~100 LOC and matches our exact needs.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const Input = @This();

// Callback shape: caller stores a fn pointer + opaque ctx.
// Fired on Enter with the current buffer contents (borrowed —
// the widget clears its buffer after the callback returns, so
// the callback must copy anything it retains).
pub const SubmitFn = *const fn (ctx: ?*anyopaque, text: []const u8) void;

// --- state ---
allocator: std.mem.Allocator,
buf: std.ArrayList(u8) = .empty,
/// Cursor position as a byte index into `buf`. Always on a UTF-8
/// codepoint boundary.
cursor: usize = 0,
on_submit: ?SubmitFn = null,
submit_ctx: ?*anyopaque = null,

pub fn init(allocator: std.mem.Allocator) Input {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Input) void {
    self.buf.deinit(self.allocator);
}

pub fn widget(self: *Input) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = eventHandler,
        .drawFn = drawFn,
    };
}

fn eventHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Input = @ptrCast(@alignCast(ptr));
    switch (event) {
        .key_press => |key| try self.handleKey(ctx, key),
        else => {},
    }
}

fn handleKey(self: *Input, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    // Submit: Enter fires the callback with the buffer contents. Match
    // every form a terminal might send Enter as so we don't silently
    // swallow submits on quirky setups:
    //   - 0x0D / 13 → standard CR (matches vaxis.Key.enter)
    //   - 0x0A / 10 → LF (vaxis remaps this to Ctrl+J in ground-state)
    //   - 57414     → kp_enter (numeric keypad Enter)
    //   - text "\r" / "\n" → some terminals deliver Enter as text
    //   - Ctrl+J    → fallback for the LF-as-Ctrl+J remap above
    const is_enter_codepoint = key.codepoint == 13 or key.codepoint == 10 or key.codepoint == 57414;
    const is_enter_text = if (key.text) |t| std.mem.eql(u8, t, "\r") or std.mem.eql(u8, t, "\n") else false;
    const is_ctrl_j = key.codepoint == 'j' and key.mods.ctrl and key.text == null;
    const is_enter = is_enter_codepoint or is_enter_text or is_ctrl_j;

    if (is_enter) {
        if (self.on_submit) |cb| {
            cb(self.submit_ctx, self.buf.items);
        }
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        ctx.consumeAndRedraw();
        return;
    }

    // Backspace: delete the codepoint left of the cursor.
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (self.cursor == 0) return;
        const new_cursor = prevCodepointBoundary(self.buf.items, self.cursor);
        const removed = self.cursor - new_cursor;
        // Shift tail left, resize.
        std.mem.copyForwards(
            u8,
            self.buf.items[new_cursor..],
            self.buf.items[self.cursor..],
        );
        self.buf.shrinkRetainingCapacity(self.buf.items.len - removed);
        self.cursor = new_cursor;
        ctx.consumeAndRedraw();
        return;
    }

    // Delete: remove the codepoint to the right of the cursor.
    if (key.matches(vaxis.Key.delete, .{})) {
        if (self.cursor >= self.buf.items.len) return;
        const next = nextCodepointBoundary(self.buf.items, self.cursor);
        const removed = next - self.cursor;
        std.mem.copyForwards(
            u8,
            self.buf.items[self.cursor..],
            self.buf.items[next..],
        );
        self.buf.shrinkRetainingCapacity(self.buf.items.len - removed);
        ctx.consumeAndRedraw();
        return;
    }

    // Cursor movement.
    if (key.matches(vaxis.Key.left, .{})) {
        self.cursor = prevCodepointBoundary(self.buf.items, self.cursor);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.right, .{})) {
        self.cursor = nextCodepointBoundary(self.buf.items, self.cursor);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
        self.cursor = 0;
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
        self.cursor = self.buf.items.len;
        ctx.consumeAndRedraw();
        return;
    }

    // Printable text insertion. `key.text` is the UTF-8 bytes
    // the terminal emitted; non-null for any visible character.
    if (key.text) |txt| {
        if (txt.len == 0) return;
        try self.buf.insertSlice(self.allocator, self.cursor, txt);
        self.cursor += txt.len;
        ctx.consumeAndRedraw();
    }
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Input = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *Input, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    // Three real cells, but visually two rows via the half-block
    // trick: top row gets `▄` (lower-half block) in
    // the tint colour with terminal-default bg, so only the bottom
    // half-cell is tinted. Middle row has solid tinted bg with the
    // text. Bottom row mirrors with `▀` (upper-half block). Net
    // painted height ≈ 0.5 + 1 + 0.5 = ~2 visual rows, text centred
    // on the midline between the two half-blocks.
    const height: u16 = 3;
    const text_row: u16 = 1;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width < 3) return surface;

    const blank_style: vaxis.Style = tui.palette.input_blank;
    const prompt_style: vaxis.Style = tui.palette.input_prompt;
    const text_style: vaxis.Style = tui.palette.input_text;
    const ghost_style: vaxis.Style = tui.palette.input_ghost;

    // Tapered side detail: the leftmost and rightmost cells of
    // the content row use `▌` / `▐` (left/right half blocks) so
    // the band's corners taper -- only the inside half of the
    // edge cell is tinted, leaving the outer half terminal
    // default. Combined with `▄` on top and `▀` on bottom, the
    // band reads as a tinted pill with rounded shoulders rather
    // than a hard rectangle.
    const half_style: vaxis.Style = .{ .fg = tui.palette.input_blank.bg };
    var bg_col: u16 = 0;
    while (bg_col < width) : (bg_col += 1) {
        // Top + bottom: full-row half-blocks.
        surface.writeCell(bg_col, 0, .{ .char = .{ .grapheme = "▄", .width = 1 }, .style = half_style });
        surface.writeCell(bg_col, 2, .{ .char = .{ .grapheme = "▀", .width = 1 }, .style = half_style });

        // Middle row: ▌ at the left edge, ▐ at the right edge,
        // solid tint everywhere in between.
        const mid_glyph: []const u8 = if (bg_col == 0)
            "▐" // tint occupies the right half of the leftmost cell
        else if (bg_col == width - 1)
            "▌" // tint occupies the left half of the rightmost cell
        else
            " ";
        const mid_style: vaxis.Style = if (bg_col == 0 or bg_col == width - 1)
            half_style
        else
            blank_style;
        surface.writeCell(bg_col, 1, .{ .char = .{ .grapheme = mid_glyph, .width = 1 }, .style = mid_style });
    }

    // Prompt glyph at col 2 -- col 0 is the tapered `▐` corner,
    // col 1 is breathing room. '›' is single-cell.
    surface.writeCell(2, text_row, .{ .char = .{ .grapheme = "›", .width = 1 }, .style = prompt_style });
    // col 3 stays blank for breathing room before the body.

    const content_col: u16 = 4;
    // Reserve the rightmost cell for the `▌` corner, plus one
    // cell of breathing room before that.
    const content_width: u16 = if (width > content_col + 2) width - content_col - 2 else 0;

    // Cursor cell is the text style with fg/bg swapped. Painted as
    // an inverted block so the user can see where insert lands.
    const cursor_style: vaxis.Style = .{
        .fg = text_style.bg,
        .bg = text_style.fg,
    };

    if (self.buf.items.len == 0) {
        writeGraphemes(ctx, surface, content_col, text_row, "Type your message or @path/to/file", ghost_style, content_width);
        if (content_width > 0) {
            surface.writeCell(content_col, text_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = cursor_style,
            });
        }
        return surface;
    }

    // Horizontal scroll: keep the cursor visible. Compute how many
    // display cells precede the cursor; if that exceeds the
    // content width, scroll right so the cursor sits near the right
    // edge.
    const cursor_cols = measureCols(self.buf.items[0..self.cursor]);
    var scroll_cols: usize = 0;
    if (cursor_cols >= content_width) {
        scroll_cols = cursor_cols - content_width + 1;
    }

    // Screen column of the cursor (after horizontal scroll). u32
    // sentinel signals "off-screen" so we don't paint a stray
    // cursor when scroll math pushes it past the visible window.
    const off_screen: u32 = std.math.maxInt(u32);
    var cursor_screen_col: u32 = off_screen;
    {
        const visible = cursor_cols - scroll_cols;
        const candidate = content_col + visible;
        if (candidate < content_col + content_width) {
            cursor_screen_col = @intCast(candidate);
        }
    }

    var col: u16 = content_col;
    var walked: usize = 0;
    var iter = ctx.graphemeIterator(self.buf.items);
    while (iter.next()) |g| {
        const grapheme = g.bytes(self.buf.items);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        if (walked < scroll_cols) {
            walked += w;
            continue;
        }
        if (col + w > content_col + content_width) break;
        const is_cursor_cell = cursor_screen_col != off_screen and col == cursor_screen_col;
        surface.writeCell(col, text_row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = if (is_cursor_cell) cursor_style else text_style,
        });
        col += if (w == 0) 1 else w;
    }

    // Cursor at the end of the buffer: paint a blank inverted cell
    // at the cursor column.
    if (cursor_screen_col != off_screen and self.cursor == self.buf.items.len) {
        surface.writeCell(@intCast(cursor_screen_col), text_row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = cursor_style,
        });
    }

    return surface;
}

// --- helpers ---

fn prevCodepointBoundary(bytes: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (bytes[j] & 0b1100_0000) == 0b1000_0000) : (j -= 1) {}
    return j;
}

fn nextCodepointBoundary(bytes: []const u8, i: usize) usize {
    if (i >= bytes.len) return bytes.len;
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
    return @min(i + seq_len, bytes.len);
}

fn measureCols(bytes: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
}

fn writeGraphemes(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
    max_cols: u16,
) void {
    if (text.len == 0 or max_cols == 0) return;
    var col = start_col;
    const limit = start_col + max_cols;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |g| {
        if (col >= limit) break;
        const grapheme = g.bytes(text);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        if (col + w > limit) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
    }
}
