//! User-message echo widget.
//!
//! Renders one sent user message as a tinted band on
//! the parent surface: a `▄` half-block top row, a solid-tint
//! content row holding the `›` prompt + body text, and a `▀`
//! half-block bottom row. The result is a self-contained block
//! that visually rhymes with the live input panel below the chat.
//!
//! This module is a paint helper rather than a vxfw `Widget` --
//! the `History` widget owns the row-flattening and viewport math,
//! and it calls in here when it encounters a user line. Keeping
//! the user-message look in one file means tweaking the band
//! shape only happens in this module instead of being smeared
//! across History's draw loop.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");

/// What kind of user-band row to paint at `screen_row`. The
/// History widget emits one of each per user line, in this order:
/// `top` half-block, then one or more `content` rows, then a
/// `bot` half-block.
pub const RowKind = enum { top, bot, content };

/// Paint a single user-band row into `surface` at `screen_row`.
/// `body`, `body_start_in_line`, and `spans` only matter for
/// `RowKind.content`; the half-block kinds ignore them.
///
/// `inset_left` / `inset_right` carve a horizontal margin out of
/// the surface so the tinted band doesn't run flush against the
/// screen edges -- matches the floating-input look.
///
/// `is_first_content` is true on the first content row of the
/// line -- that's the row that gets the `›` prompt glyph painted
/// at the leftmost band column. Continuation rows leave the
/// prompt cell blank (still tinted) so wrapped text reads as one
/// block.
pub fn paintRow(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    screen_row: u16,
    kind: RowKind,
    body: []const u8,
    body_start_in_line: usize,
    spans: ?[]tui.md.Span,
    is_first_content: bool,
    inset_left: u16,
    inset_right: u16,
) void {
    const band_start: u16 = inset_left;
    const band_end: u16 = if (surface.size.width > inset_right)
        surface.size.width - inset_right
    else
        surface.size.width;
    if (band_end <= band_start) return;

    switch (kind) {
        .top, .bot => paintHalfBlock(surface, screen_row, kind, band_start, band_end),
        .content => paintContent(ctx, surface, screen_row, body, body_start_in_line, spans, is_first_content, band_start, band_end),
    }
}

fn paintHalfBlock(
    surface: vxfw.Surface,
    screen_row: u16,
    kind: RowKind,
    band_start: u16,
    band_end: u16,
) void {
    // Half-block trick: `▄` paints only the bottom half of the
    // cell tinted (top
    // half is terminal default), `▀` mirrors with the top half.
    // Combined with a solid-tint content row in between they form
    // a band that reads as ~2 rows tall.
    const glyph: []const u8 = if (kind == .top) "▄" else "▀";
    const style: vaxis.Style = .{ .fg = tui.palette.input_blank.bg };
    var c: u16 = band_start;
    while (c < band_end) : (c += 1) {
        surface.writeCell(c, screen_row, .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = style,
        });
    }
}

fn paintContent(
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    screen_row: u16,
    body: []const u8,
    body_start_in_line: usize,
    spans: ?[]tui.md.Span,
    is_first_content: bool,
    band_start: u16,
    band_end: u16,
) void {
    // Step 1: tinted background. The leftmost and rightmost cells
    // get `▐` / `▌` half blocks so the band corners taper to
    // match the half-block top/bottom rows -- a tinted pill with
    // rounded shoulders rather than a hard rectangle.
    const half_style: vaxis.Style = .{ .fg = tui.palette.input_blank.bg };
    var c: u16 = band_start;
    while (c < band_end) : (c += 1) {
        const at_left = (c == band_start);
        const at_right = (c + 1 == band_end);
        const glyph: []const u8 = if (at_left)
            "▐"
        else if (at_right)
            "▌"
        else
            " ";
        const style: vaxis.Style = if (at_left or at_right)
            half_style
        else
            tui.palette.input_blank;
        surface.writeCell(c, screen_row, .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = style,
        });
    }

    // Step 2: prompt glyph on the first content row only. Skip
    // band_start (the `▐` corner) and band_start+1 (breathing
    // room); land at band_start+2.
    if (is_first_content and band_start + 4 <= band_end) {
        const prompt_style: vaxis.Style = tui.palette.input_prompt;
        surface.writeCell(band_start + 2, screen_row, .{
            .char = .{ .grapheme = "›", .width = 1 },
            .style = prompt_style,
        });
    }

    // Step 3: body text. Reserve band_start (`▐` corner),
    // band_start+1 (gap), band_start+2 (prompt), band_start+3
    // (gap before body). Reserve the last two cells too for the
    // gap and the `▌` corner on the right.
    const body_col: u16 = band_start + 4;
    const body_end: u16 = if (band_end >= 2) band_end - 2 else band_end;
    if (body_col >= body_end) return;
    const text_style: vaxis.Style = tui.palette.input_text;
    var col: u16 = body_col;
    var abs = body_start_in_line;
    var iter = ctx.graphemeIterator(body);
    while (iter.next()) |g| {
        if (col >= body_end) break;
        const grapheme = g.bytes(body);
        const w: u8 = @intCast(ctx.stringWidth(grapheme));
        if (col + w > body_end) break;
        const style = pickStyle(abs, text_style, spans);
        surface.writeCell(col, screen_row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = style,
        });
        col += if (w == 0) 1 else w;
        abs += grapheme.len;
    }
}

/// Innermost covering markdown span's style overlaid on `base`.
/// Mirrors `History`'s pickStyle so user messages react to spans
/// the same way agent text does.
fn pickStyle(abs: usize, base: vaxis.Style, spans: ?[]tui.md.Span) vaxis.Style {
    var s = base;
    if (spans) |sp_slice| {
        for (sp_slice) |sp| {
            if (abs >= sp.start and abs < sp.start + sp.len) {
                s = tui.palette.mdStyle(s, sp.style);
            }
        }
    }
    return s;
}
