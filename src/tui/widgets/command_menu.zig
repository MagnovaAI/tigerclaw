//! Slash-command popup, rendered above the input panel when the
//! user starts typing with `/`. Reads its filter from the input
//! buffer (the leading `/` plus whatever has been typed after);
//! Root drives selection via arrow keys and dispatches the picked
//! command on Enter.
//!
//! Visual: a single column of `<name> — <description>` rows on a
//! tinted background, matching the input panel palette so the
//! popup reads as a stacked footer extension.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const CommandMenu = @This();

pub const Item = struct {
    name: []const u8,
    description: []const u8,
};

/// Static catalog. Order = display order. Filtering is a simple
/// prefix match on `name` against the typed query (post-`/`).
pub const items: []const Item = &.{
    .{ .name = "agents", .description = "Switch agent" },
    .{ .name = "config", .description = "Show current configuration" },
    .{ .name = "skills", .description = "List installed skills (use @<name> to invoke)" },
    .{ .name = "skill", .description = "Show one skill's details: /skill <name>" },
    .{ .name = "tools", .description = "Toggle tool output (on|off)" },
    .{ .name = "lock", .description = "Lock writes to <path> (default: cwd)" },
    .{ .name = "unlock", .description = "Unlock workspace" },
    .{ .name = "plan", .description = "Plan mode (read-only)" },
    .{ .name = "ask", .description = "Toggle ask_user gate (on|off)" },
    .{ .name = "quit", .description = "Exit tigerclaw" },
};

/// `query` is the slice typed after the leading `/` (no slash).
/// Filters by case-insensitive substring; empty query keeps all.
pub fn filter(arena: std.mem.Allocator, query: []const u8) ![]const Item {
    var matches: std.ArrayList(Item) = .empty;
    for (items) |it| {
        if (query.len == 0 or asciiContains(it.name, query)) {
            try matches.append(arena, it);
        }
    }
    return matches.toOwnedSlice(arena);
}

fn asciiContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (lower(ca) != lower(cb)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// --- widget state (borrowed by drawer) ---
visible_items: []const Item = &.{},
selected: usize = 0,

pub fn widget(self: *const CommandMenu) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

/// Visual rows the popup wants. Capped so a wild number of skills
/// can't push the input box off the screen — the rest scroll out
/// of view, which is fine for this UI's volume.
pub fn rows(self: *const CommandMenu) u16 {
    if (self.visible_items.len == 0) return 0;
    const max_rows: usize = 8;
    return @intCast(@min(self.visible_items.len, max_rows));
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const CommandMenu = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse 0;
    const height: u16 = self.rows();

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (height == 0 or width == 0) return surface;

    const blank: vaxis.Style = tui.palette.input_blank;
    const text: vaxis.Style = tui.palette.input_text;
    const dim: vaxis.Style = tui.palette.input_ghost;
    const sel_style: vaxis.Style = .{ .fg = blank.bg, .bg = text.fg, .bold = true };

    // Paint background tint for every cell so the popup reads as
    // a unified band, even on rows where the description is short.
    var r: u16 = 0;
    while (r < height) : (r += 1) {
        var c: u16 = 0;
        while (c < width) : (c += 1) {
            surface.writeCell(c, r, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = blank,
            });
        }
    }

    const start_col: u16 = 2;
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        if (row >= self.visible_items.len) break;
        const item = self.visible_items[row];
        const is_selected = row == self.selected;
        const name_style: vaxis.Style = if (is_selected) sel_style else text;
        const desc_style: vaxis.Style = if (is_selected) sel_style else dim;

        // Highlight the entire line when selected so the eye snaps
        // to it; we do this by repainting the row's background
        // before writing the text.
        if (is_selected) {
            var c: u16 = 0;
            while (c < width) : (c += 1) {
                surface.writeCell(c, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = sel_style,
                });
            }
        }

        // "/<name>"
        var col = start_col;
        col = writeStr(ctx, surface, col, row, "/", name_style, width);
        col = writeStr(ctx, surface, col, row, item.name, name_style, width);
        // " — <description>"
        col = writeStr(ctx, surface, col, row, "  ", desc_style, width);
        col = writeStr(ctx, surface, col, row, item.description, desc_style, width);
    }

    return surface;
}

fn writeStr(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
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
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
    }
    return col;
}

test "filter: prefix and substring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r1 = try filter(alloc, "ag");
    try std.testing.expect(r1.len >= 1);
    try std.testing.expectEqualStrings("agents", r1[0].name);
    const r2 = try filter(alloc, "");
    try std.testing.expect(r2.len == items.len);
}
