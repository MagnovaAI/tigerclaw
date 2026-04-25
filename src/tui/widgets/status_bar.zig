//! Two-row footer status bar.
//!
//! Three logical columns (left / centre / right), each with a dim
//! label row above and a brighter value row below:
//!
//!   workspace (/directory)    sandbox      model
//!   ~                         unlocked     anthropic claude-…
//!
//! Cells outside the labels/values get the status background tint
//! so the bar reads as a unified footer. The widget borrows three
//! value strings from the parent per frame; an empty value hides
//! its column's value row but keeps the label so the layout
//! doesn't reflow.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const StatusBar = @This();

// --- state (borrowed) ---
workspace: []const u8 = "~",
sandbox: []const u8 = "trusted",
model: []const u8 = "",
/// True when sandbox is in a "warning" state (e.g. "untrusted").
/// Painted in caution amber instead of plain cream.
sandbox_caution: bool = false,

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
    const height: u16 = 1;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width == 0) return surface;

    const blank: vaxis.Style = tui.palette.status_blank;
    const value: vaxis.Style = tui.palette.status_value;
    const caution: vaxis.Style = tui.palette.status_caution;

    // Paint the bg tint across the row.
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        surface.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = blank });
    }

    // Three columns on a single line: workspace path on the left,
    // sandbox state in the middle, model on the right. We dropped
    // the redundant labels when collapsing the bar to one row;
    // the values speak for themselves on a footer.
    const left_col: u16 = 1;
    writeText(ctx, surface, left_col, 0, self.workspace, value, width);

    const sandbox_style = if (self.sandbox_caution) caution else value;
    const sb_cols = measureCols(self.sandbox);
    const center_col_value: u16 = if (width >= 8) @intCast(width / 2 - sb_cols / 2) else 0;
    writeText(ctx, surface, center_col_value, 0, self.sandbox, sandbox_style, width);

    if (self.model.len > 0) {
        const cols = measureCols(self.model);
        const right_col_value: u16 = if (width > cols + 1) @intCast(width - 1 - cols) else 0;
        writeText(ctx, surface, right_col_value, 0, self.model, value, width);
    }

    return surface;
}

fn measureCols(bytes: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
}

fn writeText(
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
