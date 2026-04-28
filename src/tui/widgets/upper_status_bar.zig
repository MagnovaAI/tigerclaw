//! Upper status bar — live tool-state strip pinned above the input.
//!
//! Shows one row per agent that has a tool in flight, formatted as
//! `<agent>: <verb> <target>`. Hidden (zero height) when no tools
//! are running, so the input snaps back up against the chat. Caps
//! at `max_rows`; older rows collapse to a `… +N more` line.
//!
//! Layout (when 2 tools are running):
//!
//!     ⠿ tiger: running zig build
//!     ⠿ bolt: writing src/foo.zig
//!     ──────────────────────────────────  <-- input panel below
//!
//! The widget reads its rows from a borrowed `[]Entry` the owner
//! refreshes per frame, so the bar stays in sync with the live
//! tool history without copying state.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

const UpperStatusBar = @This();

/// Maximum rows the bar paints. Keeps the strip from eating the
/// chat pane when many peers are mid-tool. Surplus rows collapse
/// into a single `… +N more` line.
pub const max_rows: u16 = 3;

/// One running-tool entry. `agent` is the speaker pill name (e.g.
/// `tiger`, `bolt`), `verb` is the action verb (`running`,
/// `writing`, `reading`), `target` is the args_summary preview
/// (the bash command, the file path). All three are borrowed
/// slices owned by `Root`'s history; the widget never copies.
pub const Entry = struct {
    agent: []const u8,
    verb: []const u8,
    target: []const u8,
};

// --- state (borrowed from RootWidget per frame) ---
entries: []const Entry = &.{},
/// Spinner tick. Owner increments at the chat frame rate; the bar
/// uses it to animate the leading glyph so the user can see work
/// is happening even when the row text hasn't changed in a while.
spinner_tick: u64 = 0,

pub fn widget(self: *const UpperStatusBar) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = drawFn,
    };
}

/// How many rows the bar wants at the current entry count. Owner
/// uses this to size the surface in the parent layout. Returns 0
/// when there's nothing in flight so the strip vanishes.
pub fn rowsFor(entry_count: usize) u16 {
    if (entry_count == 0) return 0;
    if (entry_count <= max_rows) return @intCast(entry_count);
    return max_rows;
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const UpperStatusBar = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const UpperStatusBar, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const want_rows = rowsFor(self.entries.len);
    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = want_rows },
    );
    if (width == 0 or want_rows == 0) return surface;

    // The strip uses the same dim-tinted bg as the lower status
    // bar so the two read as a unified frame around the input.
    const bg = tui.palette.status_blank;
    var fill_row: u16 = 0;
    while (fill_row < want_rows) : (fill_row += 1) {
        var fill_col: u16 = 0;
        while (fill_col < width) : (fill_col += 1) {
            surface.writeCell(fill_col, fill_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bg,
            });
        }
    }

    // 8-frame braille spinner — same family as the thinking row so
    // the visual idiom for "work in flight" is consistent.
    const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧" };
    const spinner = spinner_frames[@intCast(self.spinner_tick % spinner_frames.len)];
    const spinner_style = tui.palette.status_caution;
    const agent_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .bg = bg.bg, .bold = true };
    const verb_style = tui.palette.status_value;
    const sep_style = tui.palette.status_label;
    const target_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xE8, 0xC0, 0x82 } }, .bg = bg.bg };

    const visible_entries: usize = @min(self.entries.len, max_rows);
    var row: u16 = 0;
    while (row < visible_entries) : (row += 1) {
        const entry = self.entries[row];
        var col: u16 = 1;

        col = writeText(ctx, surface, col, row, spinner, spinner_style, width);
        col = writeText(ctx, surface, col, row, " ", bg, width);
        col = writeText(ctx, surface, col, row, entry.agent, agent_style, width);
        col = writeText(ctx, surface, col, row, ": ", sep_style, width);
        col = writeText(ctx, surface, col, row, entry.verb, verb_style, width);
        if (entry.target.len > 0) {
            col = writeText(ctx, surface, col, row, " ", bg, width);
            col = writeText(ctx, surface, col, row, entry.target, target_style, width);
        }
    }

    // Overflow indicator on the last visible row when there are
    // more in-flight tools than the bar can fit. The collapsed
    // row replaces the oldest entry so the user always sees the
    // freshest tool state.
    if (self.entries.len > max_rows) {
        const overflow = self.entries.len - max_rows;
        const txt = std.fmt.allocPrint(ctx.arena, "… +{d} more", .{overflow}) catch return surface;
        const last_row: u16 = max_rows - 1;
        // Repaint the row's bg to wipe the entry we displaced.
        var c: u16 = 0;
        while (c < width) : (c += 1) {
            surface.writeCell(c, last_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = bg,
            });
        }
        _ = writeText(ctx, surface, 1, last_row, txt, sep_style, width);
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
    if (text.len == 0) return start_col;
    if (row >= surface.size.height) return start_col;
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

/// Map a tool name to a human-readable verb shown in the status
/// bar. Falls back to "running <name>" for unknown tools so the
/// row always says *something* meaningful.
pub fn verbFor(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "bash")) return "running";
    if (std.mem.eql(u8, tool_name, "read_file")) return "reading";
    if (std.mem.eql(u8, tool_name, "write_file")) return "writing";
    if (std.mem.eql(u8, tool_name, "edit_file")) return "editing";
    if (std.mem.eql(u8, tool_name, "list_files")) return "listing";
    if (std.mem.eql(u8, tool_name, "glob")) return "searching";
    if (std.mem.eql(u8, tool_name, "grep")) return "grepping";
    if (std.mem.eql(u8, tool_name, "web_search")) return "searching";
    if (std.mem.eql(u8, tool_name, "fetch_url")) return "fetching";
    if (std.mem.eql(u8, tool_name, "ask_user")) return "asking";
    if (std.mem.eql(u8, tool_name, "use_skill")) return "skill";
    return tool_name;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "rowsFor: zero entries collapses to no rows" {
    try testing.expectEqual(@as(u16, 0), rowsFor(0));
}

test "rowsFor: caps at max_rows" {
    try testing.expectEqual(@as(u16, 1), rowsFor(1));
    try testing.expectEqual(@as(u16, max_rows), rowsFor(max_rows));
    try testing.expectEqual(@as(u16, max_rows), rowsFor(max_rows + 5));
}

test "verbFor: known tools map to a verb, unknown returns the name" {
    try testing.expectEqualStrings("running", verbFor("bash"));
    try testing.expectEqualStrings("reading", verbFor("read_file"));
    try testing.expectEqualStrings("writing", verbFor("write_file"));
    try testing.expectEqualStrings("editing", verbFor("edit_file"));
    try testing.expectEqualStrings("madeup", verbFor("madeup"));
}
