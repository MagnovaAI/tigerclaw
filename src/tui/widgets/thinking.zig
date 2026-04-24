//! Thinking-status row, rendered just above the input box.
//!
//! Shown only while a turn is pending. Compact single-row
//! compact spinner treatment:
//! a dim braille spinner glyph, a verb + ellipsis, and
//! optional elapsed time once the turn's been running long
//! enough to be worth announcing.
//!
//! When not pending, the widget draws nothing — its surface
//! collapses to a 0-height band so the input sits flush with
//! the history.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const Thinking = @This();

/// Ten-frame braille dot spinner. Same cadence as the old
/// header chip; at 80ms tick rate one full rotation takes 0.8s.
const frames = [_][]const u8{
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

/// Rotating verbs — picked pseudo-randomly per turn so the UI
/// feels alive instead of repeating "thinking" every time.
/// Kept short so they fit on narrow terminals.
const verbs = [_][]const u8{
    "thinking",
    "pondering",
    "considering",
    "working",
    "brewing",
    "stalking",
    "prowling",
    "sniffing",
    "musing",
    "cooking",
};

// --- state ---
pending: bool = false,
spinner_tick: u64 = 0,
/// Index into `verbs`. Bumped when a turn starts so each turn
/// gets a different verb.
verb_index: u8 = 0,
/// Milliseconds elapsed in the current turn (updated by the
/// owner from ticks). Used to surface `(Ns)` once the turn's
/// been running at least 3s — avoids flicker for fast turns.
elapsed_ms: u64 = 0,

pub fn widget(self: *const Thinking) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Thinking = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Thinking, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;

    // When not pending, collapse to zero height. The parent
    // lays out other children to fill the space.
    if (!self.pending) {
        return try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = 0 });
    }

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = 1 },
    );
    if (width == 0) return surface;

    const dim_style: vaxis.Style = tui.palette.hint;
    const accent_style: vaxis.Style = .{ .fg = tui.palette.orange };

    // Start 2 cells in so the row aligns with history's side
    // margin.
    var col: u16 = 2;

    // Spinner glyph, accent-coloured.
    const frame = frames[@intCast(self.spinner_tick % frames.len)];
    surface.writeCell(col, 0, .{
        .char = .{ .grapheme = frame, .width = 1 },
        .style = accent_style,
    });
    col += 2;

    // Verb + ellipsis. Arena-allocate so the surface cell's
    // grapheme slice stays valid until render.
    const verb = verbs[self.verb_index % verbs.len];
    const verb_line = std.fmt.allocPrint(ctx.arena, "{s}…", .{verb}) catch verb;
    col += writeText(ctx, surface, col, 0, verb_line, dim_style, width);

    // Elapsed time, shown once the turn's been running at
    // least 3 seconds. Rendered in parens with a leading space.
    if (self.elapsed_ms >= 3_000 and col + 8 < width) {
        const secs = self.elapsed_ms / 1000;
        const elapsed = std.fmt.allocPrint(ctx.arena, "  ({d}s)", .{secs}) catch "  (…)";
        _ = writeText(ctx, surface, col, 0, elapsed, dim_style, width);
    }

    return surface;
}

fn writeText(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
    max_col: u16,
) u16 {
    if (text.len == 0) return 0;
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
    return col - start_col;
}
