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
    // Submit: Enter fires the callback with the buffer contents.
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.on_submit) |cb| cb(self.submit_ctx, self.buf.items);
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
    const height: u16 = 3; // top border, input row, bottom border

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width < 3) return surface;

    const border_style: vaxis.Style = .{ .fg = tui.palette.orange };
    const prompt_style: vaxis.Style = tui.palette.prompt;
    const text_style: vaxis.Style = tui.palette.agent;
    const hint_style: vaxis.Style = tui.palette.hint;

    // Top border: ┏━━━...━━━┓ (heavy weight matches the
    // header divider rule and tiles flush across cells —
    // thin/rounded glyphs leave visible gaps in fonts with
    // any cell padding).
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "┏", .width = 1 }, .style = border_style });
    var c: u16 = 1;
    while (c < width - 1) : (c += 1) {
        surface.writeCell(c, 0, .{ .char = .{ .grapheme = "━", .width = 1 }, .style = border_style });
    }
    surface.writeCell(width - 1, 0, .{ .char = .{ .grapheme = "┓", .width = 1 }, .style = border_style });

    // Sides + prompt + content on row 1.
    surface.writeCell(0, 1, .{ .char = .{ .grapheme = "┃", .width = 1 }, .style = border_style });
    surface.writeCell(width - 1, 1, .{ .char = .{ .grapheme = "┃", .width = 1 }, .style = border_style });
    // Prompt glyph at col 1.
    surface.writeCell(1, 1, .{ .char = .{ .grapheme = "❯", .width = 1 }, .style = prompt_style });
    surface.writeCell(2, 1, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = prompt_style });

    // Content / placeholder.
    const content_col: u16 = 3;
    const content_width: u16 = if (width > 4) width - 4 else 0;
    if (self.buf.items.len == 0) {
        writeGraphemes(ctx, surface, content_col, 1, "message the tiger…", hint_style, content_width);
    } else {
        // Render as much of the buffer as fits; horizontal scroll
        // keeps the cursor visible. First compute how many cols
        // are to the left of the cursor; if that exceeds the
        // content width, scroll right so the cursor sits near the
        // right edge.
        const cursor_cols = measureCols(self.buf.items[0..self.cursor]);
        var scroll_cols: usize = 0;
        if (cursor_cols >= content_width) {
            scroll_cols = cursor_cols - content_width + 1;
        }
        // Walk the buffer grapheme by grapheme, skipping
        // `scroll_cols` leading cells, painting up to
        // `content_width` cells of text.
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
            surface.writeCell(col, 1, .{
                .char = .{ .grapheme = grapheme, .width = w },
                .style = text_style,
            });
            col += if (w == 0) 1 else w;
        }

        // Cursor. The vxfw Surface has a cursor field on the
        // top-level widget's surface; setting it here makes the
        // App.render call showCursor at the right place.
        // Cursor position tracking lives on the Surface struct,
        // but `Surface.init` returns a value copy and vxfw's
        // Widget.draw signature is `Allocator.Error!Surface`
        // (by-value). Setting `surface.cursor` here would be a
        // dead write. A proper blinking terminal cursor needs
        // either returning a mutable Surface or wrapping the
        // widget in a container that tracks cursor state —
        // follow-up.
    }

    // Bottom border: ┗━━━...━━━┛
    surface.writeCell(0, 2, .{ .char = .{ .grapheme = "┗", .width = 1 }, .style = border_style });
    c = 1;
    while (c < width - 1) : (c += 1) {
        surface.writeCell(c, 2, .{ .char = .{ .grapheme = "━", .width = 1 }, .style = border_style });
    }
    surface.writeCell(width - 1, 2, .{ .char = .{ .grapheme = "┛", .width = 1 }, .style = border_style });

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
