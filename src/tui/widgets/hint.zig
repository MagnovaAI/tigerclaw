//! Single-row hint strip rendered just above the input box.
//!
//! Layout: a left-aligned action hint ("Shift+Tab to accept
//! edits", "↑↓ scroll history") and an
//! optional right-aligned status chip ("N skills loaded", etc.).
//!
//! The widget owns nothing; it borrows two slices from the parent
//! per frame. When both are empty the row collapses to zero
//! height so the input sits flush with the chat.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const Hint = @This();

// --- state (borrowed) ---
left: []const u8 = "",
right: []const u8 = "",

pub fn widget(self: *const Hint) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Hint = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Hint, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;

    if (self.left.len == 0 and self.right.len == 0) {
        return try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 0 });
    }

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = 1 },
    );
    if (width == 0) return surface;

    const style: vaxis.Style = tui.palette.hint;

    // Left text starts at col 1 so it lines up with the input
    // prompt below (which sits at col 1 inside the panel).
    if (self.left.len > 0) {
        writeGraphemes(ctx, surface, 1, 0, self.left, style, width);
    }

    // Right text right-aligned. Measure first to know where to
    // start; if it would collide with the left text, drop it.
    if (self.right.len > 0) {
        const right_cols = measureCols(self.right);
        if (right_cols + 2 < width) {
            const start_col: u16 = @intCast(width - 1 - right_cols);
            // Avoid overlap if the texts would touch.
            const left_cols = if (self.left.len > 0) measureCols(self.left) + 1 else 0;
            if (start_col > left_cols + 2) {
                writeGraphemes(ctx, surface, start_col, 0, self.right, style, width);
            }
        }
    }

    return surface;
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
    max_col: u16,
) void {
    if (text.len == 0) return;
    var col = start_col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |g| {
        if (col >= max_col) break;
        const grapheme = g.bytes(text);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        if (col + w > max_col) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
    }
}
