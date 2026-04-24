//! vxfw header widget.
//!
//! Renders the top two rows of the TUI: a title badge on the left,
//! an agent chip + status chip on the right, and a divider rule
//! underneath. This is the first widget in the vxfw migration —
//! kept deliberately small so the bridge code in `root.zig` that
//! calls `draw(ctx)` + `surface.render(win, ...)` can be proven
//! out before the other widgets follow.
//!
//! Implements the vxfw `Widget` interface directly via a custom
//! drawFn rather than composing a `FlexRow` of sub-widgets —
//! the layout is fixed (left title, right-justified chips), and
//! the tiger-themed separator rule is a second row inside the
//! same widget, which doesn't map naturally onto a flex layout.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Header = @This();

// --- palette (duplicated from root.zig for now; extract later) ---
const orange: vaxis.Color = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } };
const amber: vaxis.Color = .{ .rgb = .{ 0xD9, 0x6A, 0x00 } };
const gold: vaxis.Color = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } };
const green: vaxis.Color = .{ .rgb = .{ 0x6B, 0xAF, 0x58 } };
const stripe: vaxis.Color = .{ .rgb = .{ 0x1A, 0x12, 0x10 } };
const smoke: vaxis.Color = .{ .rgb = .{ 0x6B, 0x5E, 0x56 } };

const title_style: vaxis.Style = .{ .fg = stripe, .bg = orange, .bold = true };
const agent_chip_style: vaxis.Style = .{ .fg = stripe, .bg = gold, .bold = true };
const status_idle_style: vaxis.Style = .{ .fg = green, .bold = true };
const status_busy_style: vaxis.Style = .{ .fg = amber, .bold = true };
const rule_accent_style: vaxis.Style = .{ .fg = orange };
const rule_smoke_style: vaxis.Style = .{ .fg = smoke };

/// Braille-dot spinner frames. Same cadence as the old
/// `drawHeader`; pulled out here so the widget is self-contained.
const spinner_frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

/// The fixed string rendered at col 0. Includes surrounding spaces
/// so the orange background reads as a proper badge.
const title_text = "  tigerclaw  ";

// --- widget state ---
agent_name: []const u8 = "tiger",
pending: bool = false,
spinner_tick: u64 = 0,

pub fn widget(self: *const Header) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Header = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Header, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height: u16 = 2;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );

    if (width == 0) return surface;

    // --- row 0: title + chips -------------------------------------------
    // Title badge at col 0.
    writeGraphemes(ctx, surface, 0, 0, title_text, title_style);

    // Right-side chips. Build the strings ON THE ARENA (not the
    // stack), because Surface cells retain slices into the
    // grapheme bytes and App.render walks those slices AFTER
    // draw() has returned — any stack-local buffer would be
    // freed by then, and the rendered chip would degenerate to
    // whatever bytes happened to survive in the popped frame.
    const agent_chip = try std.fmt.allocPrint(ctx.arena, " {s} ", .{self.agent_name});

    const spinner = spinner_frames[@intCast(self.spinner_tick % spinner_frames.len)];
    // Same-width padding on the idle chip keeps the status chip's
    // column-span stable across pending→ready transitions, which
    // used to leave trailing "dy" / "king" glyphs with the
    // hand-rolled renderer.
    const status_text = if (self.pending)
        try std.fmt.allocPrint(ctx.arena, " {s} thinking ", .{spinner})
    else
        " ● ready    ";
    const status_style = if (self.pending) status_busy_style else status_idle_style;

    const chip_cols = gwidth(ctx, agent_chip);
    const status_cols = gwidth(ctx, status_text);

    if (width > chip_cols + status_cols + 1) {
        const chip_col: u16 = @intCast(width - status_cols - chip_cols - 1);
        const status_col: u16 = @intCast(width - status_cols);
        writeGraphemes(ctx, surface, chip_col, 0, agent_chip, agent_chip_style);
        writeGraphemes(ctx, surface, status_col, 0, status_text, status_style);
    }

    // --- row 1: divider rule --------------------------------------------
    // First 18 cols in orange accent, rest in smoke — echoes the
    // title badge's coloured edge without dominating the chat below.
    const accent_cols: u16 = @min(width, 18);
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        const style = if (col < accent_cols) rule_accent_style else rule_smoke_style;
        surface.writeCell(col, 1, .{
            .char = .{ .grapheme = "━", .width = 1 },
            .style = style,
        });
    }

    return surface;
}

/// Write a UTF-8 string starting at (col, row) grapheme by grapheme,
/// honouring display-cell widths. The Surface buffer stores
/// `vaxis.Cell` values; each wide grapheme takes one cell with its
/// width set correctly, and subsequent cells in the grapheme's
/// display range are left as empty `space` cells with `width = 0`
/// so the vaxis renderer skips them.
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

fn gwidth(ctx: vxfw.DrawContext, s: []const u8) u16 {
    return @intCast(ctx.stringWidth(s));
}
