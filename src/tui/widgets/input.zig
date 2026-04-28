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
/// Directory where large pastes are stashed as `.txt` files. Set
/// once at attach time (typically `~/.tigerclaw/pastes/`). When
/// null, every paste is inlined regardless of size — pre-attach
/// fallback only.
paste_dir: ?[]const u8 = null,
/// Zig 0.16 fs APIs all require an `Io` handle; the Input widget
/// borrows the same one Root uses. Set in lockstep with
/// `paste_dir` — paste stashing is gated on both being present.
paste_io: ?std.Io = null,
/// Monotonic per-session counter so successive stashes don't
/// collide on identical wall-clock seconds.
paste_counter: u32 = 0,
/// True between `paste_start` and `paste_end` events. Most
/// terminals deliver bracketed-paste content as a stream of
/// individual key_press events between these two markers rather
/// than as a coalesced `paste` event — Vaxis's parser leaves
/// it that way too. Routing each char through the regular edit
/// path defeats the stash-to-file logic and floods history with
/// per-char redraws, so we instead append into `paste_buffer`
/// while this is set and run the stash decision once at
/// `paste_end`.
in_bracketed_paste: bool = false,
/// Bytes accumulated during a bracketed paste. Cleared on
/// `paste_end` after the buffer is committed (either inlined or
/// stashed). Owned heap buffer; freed in `deinit`.
paste_buffer: std.ArrayList(u8) = .empty,

/// Pastes at or above either threshold get stashed to a file
/// instead of inlined into the buffer. The line threshold mirrors
/// hermes-agent (5+ newlines) so multi-line code dumps collapse;
/// the byte threshold catches single-line megablobs (minified JS,
/// base64 data, paragraph-sized prose) before they explode the
/// edit buffer. 512 bytes is roughly half a typical terminal row,
/// which is the point at which inline display starts to wrap and
/// the user can no longer Esc-clear the input by feel.
const PASTE_LINE_THRESHOLD: usize = 5;
const PASTE_BYTE_THRESHOLD: usize = 512;

pub fn init(allocator: std.mem.Allocator) Input {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Input) void {
    self.buf.deinit(self.allocator);
    self.paste_buffer.deinit(self.allocator);
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
        .paste_start => {
            self.in_bracketed_paste = true;
            self.paste_buffer.clearRetainingCapacity();
            ctx.consumeAndRedraw();
        },
        .paste_end => {
            self.in_bracketed_paste = false;
            // Run the same stash-decision used for OSC52 pastes.
            // Errors are non-fatal: a paste that fails to commit
            // is dropped, and the buffer is cleared either way.
            self.handlePaste(ctx, self.paste_buffer.items) catch |err| {
                std.log.scoped(.tui_paste).warn(
                    "bracketed-paste commit failed: {s}",
                    .{@errorName(err)},
                );
            };
            self.paste_buffer.clearRetainingCapacity();
            ctx.consumeAndRedraw();
        },
        .key_press => |key| {
            // During bracketed paste, every key_press is a byte of
            // the pasted content, not user typing. Append to the
            // accumulator; commit on `paste_end`.
            if (self.in_bracketed_paste) {
                // Reconstruct the pasted byte from `key.codepoint`
                // instead of trusting `key.text`. The latter is a
                // slice into the input thread's local parser buffer
                // and is already overwritten by the time the main
                // thread drains the queued event — dereferencing it
                // segfaults on any non-trivial paste. Encoding from
                // the codepoint stays inside the bytes the event
                // carries by value.
                if (key.codepoint == 13 or key.codepoint == 10) {
                    // Pasted line breaks — terminals send them as
                    // bare CR/LF. Normalise to '\n'.
                    self.paste_buffer.append(self.allocator, '\n') catch {};
                } else if (key.codepoint > 0 and key.codepoint <= 0x10FFFF) {
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(key.codepoint), &utf8_buf) catch 0;
                    if (n > 0) self.paste_buffer.appendSlice(self.allocator, utf8_buf[0..n]) catch {};
                }
                ctx.consumeAndRedraw();
                return;
            }
            try self.handleKey(ctx, key);
        },
        .paste => |text| {
            // OSC52 paste payload. In normal operation it's allocated
            // by vaxis's parser and we own the free. But under load
            // we've observed corrupted slices arriving on this event
            // (`text.len` in the exabyte range, `text.ptr` pointing
            // at random escape-sequence bytes). The cause is the
            // same cross-thread parser race that bites `key.text` —
            // see the `.key_press` arm. Freeing such a slice
            // segfaults inside the allocator. Length-gate before
            // both reading and freeing: anything over 16 MiB is
            // almost certainly a torn read, drop it on the floor.
            // The leak risk is bounded — vaxis allocates these from
            // a per-paste buffer that resets on the next paste.
            if (text.len > 16 * 1024 * 1024) {
                std.log.scoped(.tui_paste).warn(
                    "rejecting paste with implausible len={d}; not freeing torn slice",
                    .{text.len},
                );
                return;
            }
            defer self.allocator.free(text);
            self.handlePaste(ctx, text) catch |err| {
                std.log.scoped(.tui_paste).warn(
                    "paste handler failed: {s}",
                    .{@errorName(err)},
                );
            };
        },
        else => {},
    }
}

/// Insert pasted text at the cursor. Large pastes are stashed to a
/// `.txt` file under `paste_dir` and represented in the buffer as a
/// short placeholder so the input row stays readable and the
/// downstream prompt builder can swap the placeholder for the file
/// contents (or pass the path through to a tool like `read_file`).
fn handlePaste(self: *Input, ctx: *vxfw.EventContext, text: []const u8) !void {
    if (text.len == 0) return;
    // Sanity-check the slice before reading. A wildly-out-of-range
    // pointer with a plausible-looking length is the symptom we saw
    // in the field — most likely a torn read on the queued event
    // union. Cap pastes at 16 MiB; anything bigger is almost
    // certainly a corrupt slice or a hostile/runaway clipboard,
    // and either way we don't want to walk it with `mem.count`.
    if (text.len > 16 * 1024 * 1024) {
        std.log.scoped(.tui_paste).warn(
            "rejecting paste with implausible len={d}",
            .{text.len},
        );
        return;
    }
    const newlines = std.mem.count(u8, text, "\n");
    const should_stash = self.paste_dir != null and self.paste_io != null and
        (newlines >= PASTE_LINE_THRESHOLD or text.len >= PASTE_BYTE_THRESHOLD);

    if (!should_stash) {
        try self.buf.insertSlice(self.allocator, self.cursor, text);
        self.cursor += text.len;
        ctx.consumeAndRedraw();
        return;
    }

    // Stash path: write the full payload to disk, insert a
    // human-readable placeholder. On any I/O failure fall back to a
    // truncated inline insert rather than swallowing the paste —
    // losing the user's content silently is worse than a noisy edit
    // buffer.
    const placeholder = self.stashPaste(text, newlines) catch {
        try self.buf.insertSlice(self.allocator, self.cursor, text);
        self.cursor += text.len;
        ctx.consumeAndRedraw();
        return;
    };
    defer self.allocator.free(placeholder);
    try self.buf.insertSlice(self.allocator, self.cursor, placeholder);
    self.cursor += placeholder.len;
    ctx.consumeAndRedraw();
}

/// Write `text` to a fresh file under `paste_dir` and return an
/// owned placeholder string of the form
/// `[Pasted text #N: L lines → /full/path]`. The caller owns the
/// returned slice.
fn stashPaste(self: *Input, text: []const u8, newlines: usize) ![]u8 {
    const dir_path = self.paste_dir orelse return error.NoPasteDir;
    const io = self.paste_io orelse return error.NoPasteIo;
    self.paste_counter += 1;
    const counter = self.paste_counter;

    // Ensure the directory exists. `createDirPath` is idempotent
    // and creates parents as needed, so a fresh ~/.tigerclaw works
    // the first time the user pastes.
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Filename includes a wall-clock HHMMSS stamp so the user can
    // recognise pastes by time when grepping the directory; the
    // counter disambiguates when two pastes land in the same second.
    const ts_secs_i: i64 = std.Io.Timestamp.now(io, .real).toSeconds();
    const ts_secs: u64 = if (ts_secs_i < 0) 0 else @intCast(ts_secs_i);
    const epoch = std.time.epoch.EpochSeconds{ .secs = ts_secs };
    const day_secs = epoch.getDaySeconds();
    const hh: u32 = day_secs.getHoursIntoDay();
    const mm: u32 = day_secs.getMinutesIntoHour();
    const ss: u32 = day_secs.getSecondsIntoMinute();

    var name_buf: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(
        &name_buf,
        "paste_{d}_{d:0>2}{d:0>2}{d:0>2}.txt",
        .{ counter, hh, mm, ss },
    );

    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(
        &full_path_buf,
        "{s}/{s}",
        .{ dir_path, filename },
    );

    // Open + write + close. `paste_dir` is always absolute when
    // attached from Root, so cwd-relative `createFile` resolves to
    // the right path.
    var file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, text);

    // Display line count is `newlines + 1` when the buffer doesn't
    // end with a newline (visible content extends past the last \n)
    // and `newlines` when it does — match how editors count.
    const line_count = if (text.len > 0 and text[text.len - 1] != '\n')
        newlines + 1
    else
        newlines;

    return std.fmt.allocPrint(
        self.allocator,
        "[Pasted text #{d}: {d} lines → {s}]",
        .{ counter, line_count, full_path },
    );
}

fn handleKey(self: *Input, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    // Submit: Enter fires the callback with the buffer contents. Match
    // every form a terminal might send Enter as so we don't silently
    // swallow submits on quirky setups:
    //   - 0x0D / 13 → standard CR (matches vaxis.Key.enter)
    //   - 0x0A / 10 → LF (vaxis remaps this to Ctrl+J in ground-state)
    //   - 57414     → kp_enter (numeric keypad Enter)
    //   - text "\r" / "\n" → some terminals deliver Enter as text
    //   - Ctrl+J    → fallback for the LF-as-Ctrl+J remap above
    // `key.text` is unsafe to dereference (input thread vs main
    // thread race on the parser's local buffer), so we drive every
    // detection branch off codepoint + mods. The `text "\r" / "\n"`
    // case from the old code was already covered by codepoint 13/10.
    const is_enter_codepoint = key.codepoint == 13 or key.codepoint == 10 or key.codepoint == 57414;
    const is_ctrl_j = key.codepoint == 'j' and key.mods.ctrl and key.text == null;
    const is_enter = is_enter_codepoint or is_ctrl_j;

    if (is_enter) {
        if (self.on_submit) |cb| {
            cb(self.submit_ctx, self.buf.items);
        }
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

    // Printable text insertion. We rebuild the bytes from
    // `key.codepoint` instead of dereferencing `key.text`: that
    // slice points into the input-thread parser's local buffer
    // and is overwritten by the next sequence well before the
    // main thread drains the event queue. Trusting it crashes on
    // any high-rate input (e.g. bracketed paste).
    if (key.text != null and key.codepoint > 0 and key.codepoint <= 0x10FFFF) {
        var utf8_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(key.codepoint), &utf8_buf) catch return;
        if (n == 0) return;
        try self.buf.insertSlice(self.allocator, self.cursor, utf8_buf[0..n]);
        self.cursor += n;
        ctx.consumeAndRedraw();
    }
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Input = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *Input, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    // Three real cells, but visually two rows via the half-block
    // trick: top row gets `▄` (lower-half block) in
    // the tint colour with terminal-default bg, so only the bottom
    // half-cell is tinted. Middle row has solid tinted bg with the
    // text. Bottom row mirrors with `▀` (upper-half block). Net
    // painted height ≈ 0.5 + 1 + 0.5 = ~2 visual rows, text centred
    // on the midline between the two half-blocks.
    const height: u16 = 3;
    const text_row: u16 = 1;

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
    );
    if (width < 3) return surface;

    const blank_style: vaxis.Style = tui.palette.input_blank;
    const prompt_style: vaxis.Style = tui.palette.input_prompt;
    const text_style: vaxis.Style = tui.palette.input_text;
    const ghost_style: vaxis.Style = tui.palette.input_ghost;

    // Tapered side detail: the leftmost and rightmost cells of
    // the content row use `▌` / `▐` (left/right half blocks) so
    // the band's corners taper -- only the inside half of the
    // edge cell is tinted, leaving the outer half terminal
    // default. Combined with `▄` on top and `▀` on bottom, the
    // band reads as a tinted pill with rounded shoulders rather
    // than a hard rectangle.
    const half_style: vaxis.Style = .{ .fg = tui.palette.input_blank.bg };
    var bg_col: u16 = 0;
    while (bg_col < width) : (bg_col += 1) {
        // Top + bottom: full-row half-blocks.
        surface.writeCell(bg_col, 0, .{ .char = .{ .grapheme = "▄", .width = 1 }, .style = half_style });
        surface.writeCell(bg_col, 2, .{ .char = .{ .grapheme = "▀", .width = 1 }, .style = half_style });

        // Middle row: ▌ at the left edge, ▐ at the right edge,
        // solid tint everywhere in between.
        const mid_glyph: []const u8 = if (bg_col == 0)
            "▐" // tint occupies the right half of the leftmost cell
        else if (bg_col == width - 1)
            "▌" // tint occupies the left half of the rightmost cell
        else
            " ";
        const mid_style: vaxis.Style = if (bg_col == 0 or bg_col == width - 1)
            half_style
        else
            blank_style;
        surface.writeCell(bg_col, 1, .{ .char = .{ .grapheme = mid_glyph, .width = 1 }, .style = mid_style });
    }

    // Prompt glyph at col 2 -- col 0 is the tapered `▐` corner,
    // col 1 is breathing room. '›' is single-cell.
    surface.writeCell(2, text_row, .{ .char = .{ .grapheme = "›", .width = 1 }, .style = prompt_style });
    // col 3 stays blank for breathing room before the body.

    const content_col: u16 = 4;
    // Reserve the rightmost cell for the `▌` corner, plus one
    // cell of breathing room before that.
    const content_width: u16 = if (width > content_col + 2) width - content_col - 2 else 0;

    // Cursor cell is the text style with fg/bg swapped. Painted as
    // an inverted block so the user can see where insert lands.
    const cursor_style: vaxis.Style = .{
        .fg = text_style.bg,
        .bg = text_style.fg,
    };

    if (self.buf.items.len == 0) {
        writeGraphemes(ctx, surface, content_col, text_row, "Type your message or @path/to/file", ghost_style, content_width);
        if (content_width > 0) {
            surface.writeCell(content_col, text_row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = cursor_style,
            });
        }
        return surface;
    }

    // Horizontal scroll: keep the cursor visible. Compute how many
    // display cells precede the cursor; if that exceeds the
    // content width, scroll right so the cursor sits near the right
    // edge.
    const cursor_cols = measureCols(self.buf.items[0..self.cursor]);
    var scroll_cols: usize = 0;
    if (cursor_cols >= content_width) {
        scroll_cols = cursor_cols - content_width + 1;
    }

    // Screen column of the cursor (after horizontal scroll). u32
    // sentinel signals "off-screen" so we don't paint a stray
    // cursor when scroll math pushes it past the visible window.
    const off_screen: u32 = std.math.maxInt(u32);
    var cursor_screen_col: u32 = off_screen;
    {
        const visible = cursor_cols - scroll_cols;
        const candidate = content_col + visible;
        if (candidate < content_col + content_width) {
            cursor_screen_col = @intCast(candidate);
        }
    }

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
        const is_cursor_cell = cursor_screen_col != off_screen and col == cursor_screen_col;
        surface.writeCell(col, text_row, .{
            .char = .{ .grapheme = grapheme, .width = w },
            .style = if (is_cursor_cell) cursor_style else text_style,
        });
        col += if (w == 0) 1 else w;
    }

    // Cursor at the end of the buffer: paint a blank inverted cell
    // at the cursor column.
    if (cursor_screen_col != off_screen and self.cursor == self.buf.items.len) {
        surface.writeCell(@intCast(cursor_screen_col), text_row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = cursor_style,
        });
    }

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
