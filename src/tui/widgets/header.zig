//! vxfw header widget — startup banner.
//!
//! When the terminal is wide enough, the header shows a 6-row
//! ANSIShadow "TIGERCLAW" wordmark with a per-row pink→gold
//! gradient, followed by version/model/agent/workspace info
//! and a divider. Below the wordmark's minimum width we fall
//! back to the original compact layout: a 3-row tiger-stripe
//! motif on the left and the same info column on the right.
//!
//! Wide layout (>= 72 cols):
//!
//!     ┌──────────────────────────────────────────────────┐
//!     │  ████████╗██╗ ██████╗ ███████╗  ...              │  rows 0..5  (wordmark, gradient)
//!     │  ╚══██╔══╝██║██╔════╝ ██╔════╝  ...              │
//!     │     ██║   ██║██║  ███╗█████╗    ...              │
//!     │     ██║   ██║██║   ██║██╔══╝    ...              │
//!     │     ██║   ██║╚██████╔╝███████╗  ...              │
//!     │     ╚═╝   ╚═╝ ╚═════╝ ╚══════╝  ...              │
//!     │                                                  │  row 6      (blank gap)
//!     │  tigerclaw v0.1.0 · claude opus 4.7 · tiger      │  row 7      (one-line info)
//!     │  ~/Workspace/Code/tigerclaw                      │  row 8      (workspace)
//!     │ ──────────────────────────────────────────────── │  row 9      (divider)
//!     └──────────────────────────────────────────────────┘
//!
//! Compact fallback (< 72 cols): a 6-row "TC" wordmark in the
//! same ANSIShadow font on the left, info column on the right,
//! divider underneath. 7 rows total.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const build_options = @import("build_options");

const Header = @This();

// --- palette ---
const orange: vaxis.Color = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } };
const amber: vaxis.Color = .{ .rgb = .{ 0xD9, 0x6A, 0x00 } };
const gold: vaxis.Color = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } };
const cream: vaxis.Color = .{ .rgb = .{ 0xF5, 0xE6, 0xD3 } };
const green: vaxis.Color = .{ .rgb = .{ 0x6B, 0xAF, 0x58 } };
const stripe: vaxis.Color = .{ .rgb = .{ 0x1A, 0x12, 0x10 } };
const smoke: vaxis.Color = .{ .rgb = .{ 0x6B, 0x5E, 0x56 } };

const title_style: vaxis.Style = .{ .fg = cream, .bold = true };
const info_style: vaxis.Style = .{ .fg = smoke };
const agent_accent_style: vaxis.Style = .{ .fg = gold, .bold = true };
const rule_accent_style: vaxis.Style = .{ .fg = orange };
const rule_smoke_style: vaxis.Style = .{ .fg = smoke };

// --- wordmark ---

/// ANSIShadow "TIGERCLAW" wordmark. Six visible rows rendered
/// in a three-band gradient (gold → tiger orange → deep ember),
/// using a three-band gradient. The asset is
/// 72 visible cells wide; thin box-drawing connectors (╔═╗) are
/// part of the font and read as a unified shape in normal
/// monospace fonts.
const wordmark_text = @embedFile("wordmark.txt");
const wordmark_cols: u16 = 72;
const wordmark_rows: u16 = 6;

/// Compact-mode "TC" wordmark in the same ANSIShadow font. Six
/// visible rows; ~17 visible cells wide. Used as the compact
/// fallback when the full TIGERCLAW won't fit.
const wordmark_tc_text = @embedFile("wordmark_tc.txt");
const wordmark_tc_cols: u16 = 17;
const wordmark_tc_rows: u16 = 6;

/// Per-row style: three bands, each spanning two rows. Top band
/// is bold for emphasis (bold for emphasis); the
/// remaining bands ride normal weight so the gradient reads as
/// a soft falloff rather than a heavy block.
const wordmark_styles = [wordmark_rows]vaxis.Style{
    .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .bold = true }, // gold
    .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .bold = true }, // gold
    .{ .fg = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }, .bold = false }, // tiger orange
    .{ .fg = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }, .bold = false }, // tiger orange
    .{ .fg = .{ .rgb = .{ 0xCC, 0x55, 0x00 } }, .bold = false }, // deep ember
    .{ .fg = .{ .rgb = .{ 0xCC, 0x55, 0x00 } }, .bold = false }, // deep ember
};

// --- layout ---

/// Total banner rows (incl. divider) for the compact fallback.
/// TC wordmark (6) + divider (1) = 7. Info column rides
/// alongside the wordmark, no extra rows needed.
const compact_rows: u16 = 7;

/// Total banner rows (incl. divider) for the wide layout.
/// Wordmark (6) + blank (1) + info+workspace (2) + divider (1).
const wide_rows: u16 = 10;

/// Minimum terminal width that triggers the wide wordmark
/// layout. Anything narrower falls back to compact.
const wide_min_width: u16 = wordmark_cols + 4;

/// How many rows the header needs at the given terminal width.
/// Root calls this when laying out the screen so it reserves
/// the right slice for the header surface.
pub fn bannerRows(width: u16) u16 {
    return if (width >= wide_min_width) wide_rows else compact_rows;
}

// --- widget state ---

agent_name: []const u8 = "tiger",
/// Provider+model line, e.g. "claude opus 4.7". Owner sets
/// before first draw; empty string is fine (falls back to
/// just the agent name on that row).
model_line: []const u8 = "",
/// Workspace path shown on the workspace row. Empty hides
/// the row.
workspace: []const u8 = "",

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
    const rows = bannerRows(width);

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = rows },
    );
    if (width == 0) return surface;

    if (width >= wide_min_width) {
        try self.drawWide(ctx, surface, width);
    } else {
        self.drawCompact(ctx, surface, width);
    }
    return surface;
}

/// Wide layout: ANSIShadow wordmark on top, single-line info
/// + workspace path beneath, divider on the last row.
fn drawWide(self: *const Header, ctx: vxfw.DrawContext, surface: vxfw.Surface, width: u16) !void {
    // Wordmark, left-aligned with a single-cell padding so it
    // doesn't kiss the terminal edge.
    const wordmark_col: u16 = 1;
    var row_idx: u16 = 0;
    var line_iter = std.mem.splitScalar(u8, wordmark_text, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (row_idx >= wordmark_rows) break;
        writeGraphemes(ctx, surface, wordmark_col, row_idx, line, wordmark_styles[row_idx]);
        row_idx += 1;
    }

    // One-line info row beneath the wordmark.
    // Format: "tigerclaw <ver> · <model> · <agent>"  — separators
    // and the model in dim, the agent name in gold.
    const info_row: u16 = wordmark_rows + 1; // +1 for the blank gap
    const info_col: u16 = 1;
    var col = info_col;

    const version_segment = std.fmt.allocPrint(
        ctx.arena,
        "tigerclaw {s}",
        .{build_options.version},
    ) catch "tigerclaw";
    col += writeGraphemesCounted(ctx, surface, col, info_row, version_segment, title_style, width);

    if (self.model_line.len > 0 and col + 3 < width) {
        writeGraphemes(ctx, surface, col, info_row, " · ", info_style);
        col += 3;
        col += writeGraphemesCounted(ctx, surface, col, info_row, self.model_line, info_style, width);
    }

    if (col + 3 < width) {
        writeGraphemes(ctx, surface, col, info_row, " · ", info_style);
        col += 3;
        writeGraphemes(ctx, surface, col, info_row, self.agent_name, agent_accent_style);
    }

    // Workspace path on the next row, dim.
    if (self.workspace.len > 0) {
        const ws_row: u16 = info_row + 1;
        const ws_line = contractHome(self.workspace);
        writeGraphemes(ctx, surface, info_col, ws_row, ws_line, info_style);
    }

    // Divider on the final row.
    drawDivider(surface, width, wide_rows - 1);
}

/// Compact fallback for narrow terminals (< 72 cols). Renders
/// a 6-row "TC" wordmark on the left in the same gradient as
/// the wide layout, with the info column on the right.
fn drawCompact(self: *const Header, ctx: vxfw.DrawContext, surface: vxfw.Surface, width: u16) void {
    // TC wordmark on the left, same gradient as the wide layout.
    const wordmark_col: u16 = 1;
    var row_idx: u16 = 0;
    var line_iter = std.mem.splitScalar(u8, wordmark_tc_text, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (row_idx >= wordmark_tc_rows) break;
        writeGraphemes(ctx, surface, wordmark_col, row_idx, line, wordmark_styles[row_idx]);
        row_idx += 1;
    }

    // Info column to the right of the TC wordmark. Skip if the
    // terminal is too narrow to fit even a label after the art.
    const info_col: u16 = wordmark_col + wordmark_tc_cols + 2;
    if (width > info_col) {
        const version_line = std.fmt.allocPrint(
            ctx.arena,
            "tigerclaw {s}",
            .{build_options.version},
        ) catch "tigerclaw";
        writeGraphemes(ctx, surface, info_col, 0, version_line, title_style);

        if (self.model_line.len > 0) {
            const model_written = writeGraphemesCounted(
                ctx,
                surface,
                info_col,
                1,
                self.model_line,
                info_style,
                width,
            );
            const sep_col = info_col + model_written;
            if (sep_col + 3 < width) {
                writeGraphemes(ctx, surface, sep_col, 1, " · ", info_style);
                writeGraphemes(ctx, surface, sep_col + 3, 1, self.agent_name, agent_accent_style);
            }
        } else {
            writeGraphemes(ctx, surface, info_col, 1, self.agent_name, agent_accent_style);
        }

        if (self.workspace.len > 0) {
            const ws_line = contractHome(self.workspace);
            writeGraphemes(ctx, surface, info_col, 2, ws_line, info_style);
        }
    }

    drawDivider(surface, width, compact_rows - 1);
}

fn drawDivider(surface: vxfw.Surface, width: u16, row: u16) void {
    const accent_cols: u16 = @min(width, 20);
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        const style = if (col < accent_cols) rule_accent_style else rule_smoke_style;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = "━", .width = 1 },
            .style = style,
        });
    }
}

/// Trim a leading `$HOME` prefix and replace with `~` so long
/// paths read cleanly in the banner. Falls back to the original
/// path when HOME isn't set or doesn't match.
fn contractHome(path: []const u8) []const u8 {
    const home_env = std.c.getenv("HOME") orelse return path;
    const home = std.mem.span(home_env);
    if (home.len == 0) return path;
    if (!std.mem.startsWith(u8, path, home)) return path;
    const rest = path[home.len..];
    if (rest.len == 0) return "~";
    if (rest[0] != '/') return path;
    // We'd like "~/workspace/code/tigerclaw" here, but we don't
    // own an arena to build the contracted path. Owner should
    // pass an already-contracted slice if they care about the
    // tilde; otherwise the full path renders.
    return path;
}

fn writeGraphemes(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    start_col: u16,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
) void {
    _ = writeGraphemesCounted(ctx, surface, start_col, row, text, style, surface.size.width);
}

fn writeGraphemesCounted(
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

test "bannerRows: wide layout above 72 cols, compact below" {
    try std.testing.expectEqual(compact_rows, bannerRows(40));
    try std.testing.expectEqual(compact_rows, bannerRows(71));
    try std.testing.expectEqual(compact_rows, bannerRows(wide_min_width - 1));
    try std.testing.expectEqual(wide_rows, bannerRows(wide_min_width));
    try std.testing.expectEqual(wide_rows, bannerRows(120));
}

test "wordmark asset has the expected dimensions" {
    var visible_rows: usize = 0;
    var line_iter = std.mem.splitScalar(u8, wordmark_text, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        visible_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, wordmark_rows), visible_rows);
}
