//! vxfw header widget — 4-row startup banner.
//!
//! Compact startup block. Left side is a
//! small tiger-stripe ASCII motif rendered in orange; right
//! side is the version info, current model/provider, workspace
//! path, and the ready/agent state. A full-width divider rule
//! underneath separates the banner from the chat history.
//!
//! Layout:
//!
//!     ┌──────────────────────────────────────────────────┐
//!     │                                                  │  row 0 (blank)
//!     │  <art>     tigerclaw v0.1.0-alpha                │  row 1
//!     │  <art>     claude opus 4.7 · tiger               │  row 2
//!     │  <art>     ~/Workspace/Code/tigerclaw            │  row 3
//!     │ ──────────────────────────────────────────────── │  row 4 (divider)
//!     └──────────────────────────────────────────────────┘
//!
//! Everything renders into a single 5-row Surface. Arena
//! allocations for formatted strings keep them alive through
//! the subsequent Surface.render pass.

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

const art_style: vaxis.Style = .{ .fg = orange, .bold = true };
const title_style: vaxis.Style = .{ .fg = cream, .bold = true };
const info_style: vaxis.Style = .{ .fg = smoke };
const agent_accent_style: vaxis.Style = .{ .fg = gold, .bold = true };
const rule_accent_style: vaxis.Style = .{ .fg = orange };
const rule_smoke_style: vaxis.Style = .{ .fg = smoke };

/// Three rows of tiger-stripe block art. Each row is 9 display
/// cells wide. Rendered in orange, tiger colour. Abstracted
/// rather than literal — reads as a striped shape without
/// trying to be a recognisable face.
const art = [_][]const u8{
    " ▗▟████▙▖",
    "▐█▀ ██ ▀█▌",
    " ▀▙▄██▄▟▀",
};
const art_cols: u16 = 10;

/// Height of the full banner, including divider. Root uses
/// this to reserve space.
pub const banner_rows: u16 = 5;

// --- widget state ---
agent_name: []const u8 = "tiger",
/// Provider+model line, e.g. "claude opus 4.7". Owner sets
/// before first draw; empty string is fine (falls back to
/// just the agent name on that row).
model_line: []const u8 = "",
/// Workspace path shown on the third text row. Empty hides
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

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = banner_rows },
    );
    if (width == 0) return surface;

    // Row 0 stays blank — buffer inits to the default cell, so
    // no explicit writes are needed.

    // --- art on rows 1..3, left-aligned with 1 cell padding ---
    const art_col: u16 = 1;
    for (art, 0..) |art_row, i| {
        const row: u16 = @intCast(1 + i);
        if (row >= banner_rows - 1) break;
        writeGraphemes(ctx, surface, art_col, row, art_row, art_style);
    }

    // --- info on the right side of the art ---
    const info_col: u16 = art_col + art_cols + 3;
    if (width > info_col) {
        // Row 1: title + version.
        const version_line = std.fmt.allocPrint(
            ctx.arena,
            "tigerclaw {s}",
            .{build_options.version},
        ) catch "tigerclaw";
        writeGraphemes(ctx, surface, info_col, 1, version_line, title_style);

        // Row 2: model line + agent accent.
        // Renders as "claude opus 4.7 · tiger" with the model in
        // dim and the agent name in gold for quick visual parse.
        if (self.model_line.len > 0) {
            const model_written = writeGraphemesCounted(
                ctx,
                surface,
                info_col,
                2,
                self.model_line,
                info_style,
                width,
            );
            const sep_col = info_col + model_written;
            if (sep_col + 3 < width) {
                writeGraphemes(ctx, surface, sep_col, 2, " · ", info_style);
                writeGraphemes(ctx, surface, sep_col + 3, 2, self.agent_name, agent_accent_style);
            }
        } else {
            writeGraphemes(ctx, surface, info_col, 2, self.agent_name, agent_accent_style);
        }

        // Row 3: workspace path (dim).
        if (self.workspace.len > 0) {
            const ws_line = contractHome(self.workspace);
            writeGraphemes(ctx, surface, info_col, 3, ws_line, info_style);
        }
    }

    // --- divider rule on the final row ---
    const rule_row: u16 = banner_rows - 1;
    const accent_cols: u16 = @min(width, 20);
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        const style = if (col < accent_cols) rule_accent_style else rule_smoke_style;
        surface.writeCell(col, rule_row, .{
            .char = .{ .grapheme = "━", .width = 1 },
            .style = style,
        });
    }

    return surface;
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
