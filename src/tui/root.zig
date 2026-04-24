//! Full-screen chat TUI.
//!
//! Launched by `tigerclaw` (no subcommand). Connects to a locally
//! running gateway on 127.0.0.1:8765 and presents a chat loop with
//! an agent switcher — message history scrolls above, text input
//! below, status bar in between.
//!
//! # Design
//!
//! * Built on libvaxis (vendored in packages/vaxis).
//! * Event-driven — vaxis's Loop pushes key presses, resize, and
//!   focus events into a queue; a worker thread pushes
//!   `turn_chunk` / `turn_done` / `turn_error` variants for the
//!   active turn, and a ticker thread pushes `tick` while pending
//!   so the spinner animates without needing input. The main loop
//!   stays responsive for keys and resizes while the HTTP
//!   round-trip runs.
//! * History is an ArrayList of lines with per-line text stored in
//!   its own ArrayList(u8) so streamed chunks can append in place
//!   without reallocating the history entry.
//!
//! # Gateway contract
//!
//! POST /sessions/<agent>/turns with `{"message": "..."}` and
//! `Accept: text/event-stream`. The gateway replies with a sequence
//! of `event: token` frames (one per source line) followed by a
//! single `event: done`. The SSE frame grammar is duplicated from
//! `cli/commands/agent.zig` so the worker can emit one vaxis event
//! per frame instead of rendering a concatenated string.
//!
//! # Agent switcher
//!
//! On launch, scans `$HOME/.tigerclaw/agents/` for subdirectories
//! and treats each as a selectable agent. `Ctrl-N` / `Ctrl-P`
//! cycle forward / back; `Ctrl-E` opens an inline picker overlay.
//! If the scan returns nothing, the caller-supplied default agent
//! is the only option.

const std = @import("std");
const vaxis = @import("vaxis");
const http_client = @import("../cli/commands/http_client.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// One decoded SSE token frame. Slice is heap-allocated on the
    /// worker thread; the main loop takes ownership and frees after
    /// appending to history.
    turn_chunk: []u8,
    /// Stream terminator. Re-enables input.
    turn_done,
    /// Worker hit a transport / protocol error. Slice is owned and
    /// freed by the main loop after rendering as a system line.
    turn_error: []u8,
    /// Low-frequency heartbeat from the spinner ticker while a turn
    /// is pending. Drives spinner animation without relying on
    /// incoming keys.
    tick,
};

const Line = struct {
    role: Role,
    text: std.ArrayList(u8),

    const Role = enum { user, agent, system };
};

pub const Options = struct {
    base_url: []const u8 = "http://127.0.0.1:8765",
    agent: []const u8 = "tiger",
    /// Caller-resolved `$HOME`. Empty disables the agent-directory
    /// scan; only the default agent will appear. Resolving HOME
    /// itself is main.zig's job (matches the convention used by
    /// diag / gateway / service commands).
    home: []const u8 = "",
};

const EventLoop = vaxis.Loop(Event);

/// Palette tuned for dark terminals. Indexes into the terminal's
/// own 256-color map rather than hard-coded RGB so the colors
/// remain coherent under the user's scheme.
const palette = struct {
    const title: vaxis.Style = .{ .fg = .{ .index = 45 }, .bold = true };
    const agent_chip: vaxis.Style = .{ .fg = .{ .index = 16 }, .bg = .{ .index = 45 }, .bold = true };
    const status_idle: vaxis.Style = .{ .fg = .{ .index = 42 }, .bold = true };
    const status_busy: vaxis.Style = .{ .fg = .{ .index = 214 }, .bold = true };
    const separator: vaxis.Style = .{ .fg = .{ .index = 240 } };
    const user: vaxis.Style = .{ .fg = .{ .index = 117 }, .bold = true };
    const agent: vaxis.Style = .{ .fg = .{ .index = 252 } };
    const system: vaxis.Style = .{ .fg = .{ .index = 244 }, .italic = true };
    const prompt: vaxis.Style = .{ .fg = .{ .index = 45 }, .bold = true };
    const hint: vaxis.Style = .{ .fg = .{ .index = 240 }, .italic = true };
    const picker_border: vaxis.Style = .{ .fg = .{ .index = 45 } };
    const picker_item: vaxis.Style = .{ .fg = .{ .index = 252 } };
    const picker_item_selected: vaxis.Style = .{ .fg = .{ .index = 16 }, .bg = .{ .index = 45 }, .bold = true };
};

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

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

    var loop: EventLoop = .{ .vaxis = &vx, .tty = &tty };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    var input = vaxis.widgets.TextInput.init(allocator);
    defer input.deinit();

    var history: std.ArrayList(Line) = .empty;
    defer {
        for (history.items) |*l| l.text.deinit(allocator);
        history.deinit(allocator);
    }

    // Load the agent roster. On failure we still run with the
    // caller-supplied default so the TUI is usable against any
    // configuration.
    var agents = AgentList.init(allocator);
    defer agents.deinit();
    try agents.loadFromDisk(io, opts.home);
    const default_index = agents.findOrAppend(opts.agent) catch 0;
    var selected: usize = default_index;

    try appendLine(&history, allocator, .system, "connected. ctrl-c to quit.");

    var spinner_tick: u64 = 0;
    var picker_open: bool = false;
    var picker_cursor: usize = selected;

    // Ticker lifecycle — only alive while a turn is pending. The
    // main thread owns the flag and joins the ticker on done/error.
    var ticker_stop: std.atomic.Value(bool) = .init(false);
    var ticker_thread: ?std.Thread = null;

    var pending: bool = false;
    var pending_agent_line: ?usize = null;
    var pending_saw_text: bool = false;

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
                    ticker_stop.store(true, .release);
                    if (ticker_thread) |t| t.join();
                    return;
                }

                if (picker_open) {
                    handlePickerKey(key, &picker_open, &picker_cursor, &selected, agents.items());
                } else if (key.matches('e', .{ .ctrl = true }) and !pending) {
                    picker_cursor = selected;
                    picker_open = true;
                } else if (key.matches('n', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = (selected + 1) % agents.count();
                } else if (key.matches('p', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = if (selected == 0) agents.count() - 1 else selected - 1;
                } else if (key.matches(vaxis.Key.enter, .{}) and !pending) {
                    const typed = try currentInput(allocator, &input);
                    defer allocator.free(typed);
                    if (typed.len == 0) continue;

                    const user_line = try makeLine(allocator, .user, typed);
                    try history.append(allocator, user_line);
                    input.clearAndFree();

                    // Reserve the agent line up front so streamed
                    // chunks have a stable slot to append to. The
                    // line starts empty; if the worker errors
                    // before any chunk lands it gets dropped.
                    const agent_line = try makeLine(allocator, .agent, "");
                    try history.append(allocator, agent_line);
                    pending_agent_line = history.items.len - 1;
                    pending_saw_text = false;
                    pending = true;

                    const message_copy = try allocator.dupe(u8, typed);
                    const ctx = try allocator.create(WorkerCtx);
                    ctx.* = .{
                        .allocator = allocator,
                        .io = io,
                        .loop = &loop,
                        .base_url = opts.base_url,
                        .agent = agents.name(selected),
                        .message = message_copy,
                    };
                    const t = std.Thread.spawn(.{}, workerMain, .{ctx}) catch |err| {
                        allocator.free(message_copy);
                        allocator.destroy(ctx);
                        if (pending_agent_line) |idx| {
                            var dropped = history.orderedRemove(idx);
                            dropped.text.deinit(allocator);
                        }
                        pending_agent_line = null;
                        pending = false;
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "! could not spawn worker: {s}",
                            .{@errorName(err)},
                        );
                        defer allocator.free(msg);
                        try appendLine(&history, allocator, .system, msg);
                        try drawFrame(&vx, writer, &input, history.items, agents.items(), selected, pending, spinner_tick, picker_open, picker_cursor);
                        continue;
                    };
                    t.detach();

                    // Start the spinner ticker. It posts `.tick`
                    // every 80ms until asked to stop.
                    ticker_stop.store(false, .release);
                    ticker_thread = std.Thread.spawn(.{}, tickerMain, .{TickerCtx{
                        .io = io,
                        .loop = &loop,
                        .stop = &ticker_stop,
                    }}) catch |err| blk: {
                        std.log.scoped(.tui).warn("spinner ticker spawn failed: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                } else if (!pending) {
                    try input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(allocator, writer, ws),
            .tick => spinner_tick +%= 1,
            .turn_chunk => |chunk| {
                defer allocator.free(chunk);
                if (pending_agent_line) |idx| {
                    var line = &history.items[idx];
                    try appendSanitizedUtf8(&line.text, allocator, chunk);
                    pending_saw_text = true;
                }
            },
            .turn_done => {
                if (!pending_saw_text) {
                    if (pending_agent_line) |idx| {
                        var dropped = history.orderedRemove(idx);
                        dropped.text.deinit(allocator);
                    }
                }
                pending_agent_line = null;
                pending_saw_text = false;
                pending = false;
                ticker_stop.store(true, .release);
                if (ticker_thread) |t| {
                    t.join();
                    ticker_thread = null;
                }
            },
            .turn_error => |msg| {
                defer allocator.free(msg);
                if (pending_agent_line) |idx| {
                    if (!pending_saw_text) {
                        var dropped = history.orderedRemove(idx);
                        dropped.text.deinit(allocator);
                    }
                }
                try appendLine(&history, allocator, .system, msg);
                pending_agent_line = null;
                pending_saw_text = false;
                pending = false;
                ticker_stop.store(true, .release);
                if (ticker_thread) |t| {
                    t.join();
                    ticker_thread = null;
                }
            },
            else => {},
        }

        try drawFrame(&vx, writer, &input, history.items, agents.items(), selected, pending, spinner_tick, picker_open, picker_cursor);
    }
}

fn handlePickerKey(
    key: vaxis.Key,
    picker_open: *bool,
    cursor: *usize,
    selected: *usize,
    agents: []const []const u8,
) void {
    if (agents.len == 0) {
        picker_open.* = false;
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        picker_open.* = false;
    } else if (key.matches(vaxis.Key.enter, .{})) {
        selected.* = cursor.*;
        picker_open.* = false;
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        cursor.* = if (cursor.* == 0) agents.len - 1 else cursor.* - 1;
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        cursor.* = (cursor.* + 1) % agents.len;
    }
}

fn drawFrame(
    vx: *vaxis.Vaxis,
    writer: anytype,
    input: *vaxis.widgets.TextInput,
    history: []const Line,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
    picker_open: bool,
    picker_cursor: usize,
) !void {
    try draw(vx, input, history, agents, selected, pending, spinner_tick, picker_open, picker_cursor);
    try vx.render(writer);
    try writer.flush();
}

/// Join both halves of the TextInput's gap buffer into a contiguous
/// slice owned by the caller. Vaxis exposes `firstHalf` / `secondHalf`
/// directly rather than a flat `items` field.
fn currentInput(allocator: std.mem.Allocator, input: *vaxis.widgets.TextInput) ![]u8 {
    const a = input.buf.firstHalf();
    const b = input.buf.secondHalf();
    const out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn makeLine(allocator: std.mem.Allocator, role: Line.Role, text: []const u8) !Line {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendSanitizedUtf8(&buf, allocator, text);
    return .{ .role = role, .text = buf };
}

fn appendLine(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    role: Line.Role,
    text: []const u8,
) !void {
    const line = try makeLine(allocator, role, text);
    try history.append(allocator, line);
}

fn draw(
    vx: *vaxis.Vaxis,
    input: *vaxis.widgets.TextInput,
    history: []const Line,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
    picker_open: bool,
    picker_cursor: usize,
) !void {
    const win = vx.window();
    win.clear();

    // Row 0: header. Row 1: separator. Rest: history, then status
    // hint above a 3-row input box.
    drawHeader(win, agents, selected, pending, spinner_tick);

    const header_rows: i32 = 2;
    const footer_rows: i32 = 4; // status hint + 3-row input box
    const history_height_i: i32 = @as(i32, @intCast(win.height)) - header_rows - footer_rows;
    if (history_height_i > 0) {
        const pane = win.child(.{
            .x_off = 1,
            .y_off = header_rows,
            .width = if (win.width > 2) win.width - 2 else win.width,
            .height = @intCast(history_height_i),
        });
        drawHistory(pane, history);
    }

    if (win.height >= 4) {
        const status_row: u16 = @intCast(@as(i32, @intCast(win.height)) - footer_rows);
        drawStatusHint(win, status_row, agents, selected);
    }

    if (win.height >= 3) {
        const input_child = win.child(.{
            .x_off = 0,
            .y_off = @intCast(@as(i32, @intCast(win.height)) - 3),
            .width = win.width,
            .height = 3,
            .border = .{ .where = .all, .style = palette.separator },
        });
        _ = input_child.printSegment(
            .{ .text = "› ", .style = palette.prompt },
            .{ .row_offset = 0, .col_offset = 0 },
        );
        const input_inner = input_child.child(.{
            .x_off = 2,
            .y_off = 0,
            .width = if (input_child.width > 2) input_child.width - 2 else 1,
            .height = 1,
        });
        input.draw(input_inner);
    }

    if (picker_open and agents.len > 0) {
        drawPicker(win, agents, picker_cursor);
    }
}

fn drawHeader(
    win: vaxis.Window,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
) void {
    // Left: title.
    _ = win.printSegment(
        .{ .text = " tigerclaw ", .style = palette.title },
        .{ .row_offset = 0, .col_offset = 0 },
    );

    // Right: agent chip + status chip, right-justified.
    var chip_buf: [128]u8 = undefined;
    const agent_name = if (agents.len > 0) agents[selected] else "—";
    const chip = std.fmt.bufPrint(&chip_buf, " {s} ", .{agent_name}) catch " agent ";

    const spinner = spinner_frames[@intCast(spinner_tick % spinner_frames.len)];
    var status_buf: [64]u8 = undefined;
    const status_text = if (pending)
        (std.fmt.bufPrint(&status_buf, " {s} thinking ", .{spinner}) catch " … ")
    else
        " ● ready ";

    const chip_len: usize = visualWidth(chip);
    const status_len: usize = visualWidth(status_text);
    const width: usize = @intCast(win.width);

    if (width > chip_len + status_len + 1) {
        const chip_col: u16 = @intCast(width - status_len - chip_len - 1);
        const status_col: u16 = @intCast(width - status_len);
        _ = win.printSegment(
            .{ .text = chip, .style = palette.agent_chip },
            .{ .row_offset = 0, .col_offset = chip_col },
        );
        _ = win.printSegment(
            .{ .text = status_text, .style = if (pending) palette.status_busy else palette.status_idle },
            .{ .row_offset = 0, .col_offset = status_col },
        );
    }

    if (win.height > 1 and win.width > 0) {
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            _ = win.printSegment(
                .{ .text = "─", .style = palette.separator },
                .{ .row_offset = 1, .col_offset = col },
            );
        }
    }
}

fn drawStatusHint(
    win: vaxis.Window,
    row: u16,
    agents: []const []const u8,
    selected: usize,
) void {
    var buf: [256]u8 = undefined;
    const hint = if (agents.len > 1)
        (std.fmt.bufPrint(
            &buf,
            "ctrl-n/p cycle agent ({d}/{d})  ·  ctrl-e pick  ·  enter send  ·  ctrl-c quit",
            .{ selected + 1, agents.len },
        ) catch "ctrl-c quit")
    else
        "enter send  ·  ctrl-c quit";

    _ = win.printSegment(
        .{ .text = hint, .style = palette.hint },
        .{ .row_offset = row, .col_offset = 1 },
    );
}

/// Return the largest byte count ≤ `max` that ends on a UTF-8
/// codepoint boundary. Continuation bytes (`10xxxxxx`) never start a
/// codepoint, so we walk back from `max` until we find a leading byte.
/// ASCII-only strings return `max` in one pass.
fn safeUtf8Take(bytes: []const u8, max: usize) usize {
    if (max >= bytes.len) return bytes.len;
    if (max == 0) return 0;
    var n = max;
    while (n > 0 and (bytes[n] & 0b1100_0000) == 0b1000_0000) : (n -= 1) {}
    return n;
}

/// Copy `bytes` into `out`, replacing any byte that is not part of a
/// valid UTF-8 sequence with `?`. This prevents corrupted input (stray
/// escape-sequence bytes, partial sequences from a glitchy terminal,
/// truncated provider chunks) from reaching the renderer and showing
/// as `�`-glyphs in the chat history.
fn appendSanitizedUtf8(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    var i: usize = 0;
    while (i < bytes.len) {
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
            0;

        if (seq_len == 0 or i + seq_len > bytes.len) {
            try list.append(allocator, '?');
            i += 1;
            continue;
        }
        if (std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len])) {
            // U+FFFD (encoded as EF BF BD) is the Unicode replacement
            // character. Its presence always means an upstream layer
            // already substituted it for invalid data — emitting it to
            // the terminal produces the black-diamond-question-mark
            // glyph. Drop it silently; nothing legitimate uses it.
            if (seq_len == 3 and bytes[i] == 0xEF and bytes[i + 1] == 0xBF and bytes[i + 2] == 0xBD) {
                i += 3;
                continue;
            }
            try list.appendSlice(allocator, bytes[i .. i + seq_len]);
            i += seq_len;
        } else {
            try list.append(allocator, '?');
            i += 1;
        }
    }
}

fn drawHistory(pane: vaxis.Window, history: []const Line) void {
    // Walk newest-first, rendering upward. Long lines wrap at pane
    // width with a naive byte-based split — good enough for ASCII
    // and passable for UTF-8 text without zero-width combiners.
    var row_cursor: i32 = @as(i32, @intCast(pane.height)) - 1;

    var i: usize = history.len;
    while (i > 0 and row_cursor >= 0) {
        i -= 1;
        const line = history[i];
        const prefix = switch (line.role) {
            .user => "› ",
            .agent => "‹ ",
            .system => "· ",
        };

        const width: usize = @intCast(pane.width);
        const avail = if (width > prefix.len) width - prefix.len else 1;

        var rows_needed: usize = 1;
        var remaining = line.text.items;
        if (remaining.len > avail) {
            rows_needed = (remaining.len + avail - 1) / avail;
        }
        if (rows_needed > 32) rows_needed = 32;

        var start_row = row_cursor - @as(i32, @intCast(rows_needed - 1));
        if (start_row < 0) {
            const drop = @as(usize, @intCast(-start_row));
            if (drop >= rows_needed) {
                row_cursor -= @intCast(rows_needed);
                continue;
            }
            const skip_bytes = drop * avail;
            if (skip_bytes < remaining.len) {
                remaining = remaining[skip_bytes..];
                rows_needed -= drop;
            }
            start_row = 0;
        }

        const style: vaxis.Style = switch (line.role) {
            .user => palette.user,
            .agent => palette.agent,
            .system => palette.system,
        };

        var row = start_row;
        _ = pane.printSegment(
            .{ .text = prefix, .style = style },
            .{ .row_offset = @intCast(row), .col_offset = 0 },
        );

        var col_offset: usize = prefix.len;
        while (remaining.len > 0 and row < pane.height) {
            const take = safeUtf8Take(remaining, avail);
            _ = pane.printSegment(
                .{ .text = remaining[0..take], .style = style },
                .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) },
            );
            remaining = remaining[take..];
            row += 1;
            col_offset = prefix.len;
        }

        row_cursor -= @intCast(rows_needed);
    }
}

fn drawPicker(
    win: vaxis.Window,
    agents: []const []const u8,
    cursor: usize,
) void {
    const max_items: usize = 12;
    const visible: usize = @min(agents.len, max_items);
    const panel_h: u16 = @intCast(visible + 2);

    var longest: usize = 0;
    for (agents) |name| if (name.len > longest) {
        longest = name.len;
    };
    const desired = longest + 6;
    const min_w: usize = 24;
    const max_w: usize = @intCast(win.width);
    const panel_w: u16 = @intCast(std.math.clamp(desired, min_w, if (max_w > 4) max_w - 4 else max_w));

    if (panel_h + 2 > win.height or panel_w + 2 > win.width) return;

    const x: i17 = @intCast(@divTrunc(@as(i32, @intCast(win.width)) - @as(i32, panel_w), 2));
    const y: i17 = @intCast(@divTrunc(@as(i32, @intCast(win.height)) - @as(i32, panel_h), 2));

    const panel = win.child(.{
        .x_off = x,
        .y_off = y,
        .width = panel_w,
        .height = panel_h,
        .border = .{ .where = .all, .style = palette.picker_border },
    });

    _ = panel.printSegment(
        .{ .text = " select agent ", .style = palette.picker_border },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    const list_w: u16 = if (panel.width > 2) panel.width - 2 else 0;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const name = agents[i];
        const style = if (i == cursor) palette.picker_item_selected else palette.picker_item;
        var line_buf: [256]u8 = undefined;
        const marker: []const u8 = if (i == cursor) "➤ " else "  ";
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ marker, name }) catch name;
        const take = @min(line.len, list_w);
        _ = panel.printSegment(
            .{ .text = line[0..take], .style = style },
            .{ .row_offset = @intCast(i + 1), .col_offset = 1 },
        );
        if (take < list_w) {
            var pad_buf: [256]u8 = undefined;
            const pad_len = @min(list_w - take, pad_buf.len);
            @memset(pad_buf[0..pad_len], ' ');
            _ = panel.printSegment(
                .{ .text = pad_buf[0..pad_len], .style = style },
                .{ .row_offset = @intCast(i + 1), .col_offset = @intCast(1 + take) },
            );
        }
    }
}

/// Count codepoints in a UTF-8 slice. Good enough for the header
/// layout math — most glyphs we draw are single-cell.
fn visualWidth(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const seq_len: usize = if (b < 0x80) 1 else if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        i += seq_len;
        count += 1;
    }
    return count;
}

/// In-memory roster of agents. Names are owned slices; the struct
/// frees them on `deinit`.
const AgentList = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) AgentList {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *AgentList) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
    }

    fn count(self: *const AgentList) usize {
        return self.names.items.len;
    }

    fn items(self: *const AgentList) []const []const u8 {
        return @ptrCast(self.names.items);
    }

    fn name(self: *const AgentList, idx: usize) []const u8 {
        return self.names.items[idx];
    }

    fn append(self: *AgentList, n: []const u8) !void {
        const copy = try self.allocator.dupe(u8, n);
        errdefer self.allocator.free(copy);
        try self.names.append(self.allocator, copy);
    }

    fn findOrAppend(self: *AgentList, n: []const u8) !usize {
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, n)) return i;
        }
        try self.append(n);
        return self.names.items.len - 1;
    }

    /// Populate from `<home>/.tigerclaw/agents/`. Empty or missing
    /// home short-circuits silently — the caller still appends the
    /// default agent so the TUI is usable.
    fn loadFromDisk(self: *AgentList, io: std.Io, home: []const u8) !void {
        if (home.len == 0) return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.tigerclaw/agents", .{home}) catch return;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            try self.append(entry.name);
        }
        // Sort so agent order is deterministic across launches —
        // the scan order from the filesystem isn't stable.
        std.mem.sort([]u8, self.names.items, {}, lessThanName);
    }
};

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// State handed to the worker thread. The worker owns `message` and
/// frees it on exit; the context struct itself is freed last.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *EventLoop,
    base_url: []const u8,
    agent: []const u8,
    message: []u8,
};

fn workerMain(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.message);
        ctx.allocator.destroy(ctx);
    }

    runTurn(ctx) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "! gateway error: {s}",
            .{@errorName(err)},
        ) catch {
            ctx.loop.postEvent(.turn_done);
            return;
        };
        ctx.loop.postEvent(.{ .turn_error = msg });
        return;
    };
    ctx.loop.postEvent(.turn_done);
}

fn runTurn(ctx: *WorkerCtx) !void {
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/{s}/turns",
        .{ ctx.base_url, ctx.agent },
    );

    const body_json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .agent = ctx.agent,
        .message = ctx.message,
    }, .{});
    defer ctx.allocator.free(body_json);

    var resp_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer resp_buf.deinit();

    _ = try http_client.send(
        ctx.allocator,
        ctx.io,
        .{
            .method = .POST,
            .url = url,
            .json_body = body_json,
            .accept = "text/event-stream",
        },
        &resp_buf.writer,
        .{},
    );

    try dispatchSseBody(ctx, resp_buf.written());
}

/// Walk the SSE body, posting one `turn_chunk` per `event: token`.
/// Duplicates the `renderSse` framing grammar (rather than routing
/// through the shared helper) so we can emit per-frame events
/// instead of a single concatenated string.
fn dispatchSseBody(ctx: *WorkerCtx, body: []const u8) !void {
    var it = std.mem.splitSequence(u8, body, "\n\n");
    while (it.next()) |frame| {
        var event_name: []const u8 = "message";
        var data: []const u8 = "";
        var had_data: bool = false;

        var lines = std.mem.splitScalar(u8, frame, '\n');
        while (lines.next()) |line| {
            const clean = std.mem.trimEnd(u8, line, "\r");
            if (clean.len == 0) continue;
            if (std.mem.startsWith(u8, clean, "event:")) {
                event_name = std.mem.trim(u8, clean[6..], " \t");
            } else if (std.mem.startsWith(u8, clean, "data:")) {
                var payload = clean[5..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                data = payload;
                had_data = true;
            }
        }

        if (std.mem.eql(u8, event_name, "token") and had_data) {
            const owned = try ctx.allocator.dupe(u8, data);
            ctx.loop.postEvent(.{ .turn_chunk = owned });
        } else if (std.mem.eql(u8, event_name, "done")) {
            return;
        }
    }
}

const TickerCtx = struct {
    io: std.Io,
    loop: *EventLoop,
    stop: *std.atomic.Value(bool),
};

fn tickerMain(ctx: TickerCtx) void {
    // 80ms cadence — fast enough that the spinner feels alive,
    // slow enough that the vaxis queue doesn't saturate.
    const interval_ns: u64 = 80 * std.time.ns_per_ms;
    while (!ctx.stop.load(.acquire)) {
        std.Io.sleep(ctx.io, std.Io.Duration.fromNanoseconds(interval_ns), .awake) catch {};
        if (ctx.stop.load(.acquire)) break;
        // tryPostEvent so a saturated queue drops ticks instead of
        // blocking the ticker on a stalled UI.
        _ = ctx.loop.tryPostEvent(.tick);
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "safeUtf8Take: ASCII is truncated at the requested byte count" {
    try testing.expectEqual(@as(usize, 5), safeUtf8Take("hello world", 5));
    try testing.expectEqual(@as(usize, 11), safeUtf8Take("hello world", 100));
    try testing.expectEqual(@as(usize, 0), safeUtf8Take("x", 0));
}

test "safeUtf8Take: never splits a multi-byte codepoint" {
    // "·" is U+00B7, encoded as 0xC2 0xB7 (2 bytes). A naive byte
    // truncation at max=1 would leave a dangling 0xC2 — the helper
    // must back up to the start of the codepoint instead.
    const s = "a·b";
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 1)); // "a"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 2)); // back up: "a"
    try testing.expectEqual(@as(usize, 3), safeUtf8Take(s, 3)); // "a·"
    try testing.expectEqual(@as(usize, 4), safeUtf8Take(s, 4)); // "a·b"
}

test "appendSanitizedUtf8: replaces stray lead byte with ?" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // `z` + stray 0xE2 (lead byte with no continuation) + `y` — the
    // real-world symptom the sanitizer exists to stop.
    try appendSanitizedUtf8(&buf, testing.allocator, "z\xE2y");
    try testing.expectEqualStrings("z?y", buf.items);
}

test "appendSanitizedUtf8: preserves valid multi-byte sequences" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendSanitizedUtf8(&buf, testing.allocator, "Hey \xF0\x9F\x91\x8B world");
    try testing.expectEqualStrings("Hey \xF0\x9F\x91\x8B world", buf.items);
}

test "appendSanitizedUtf8: drops U+FFFD replacement characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // EF BF BD is U+FFFD — upstream already substituted this for bad
    // input, so we drop it rather than forwarding the black-diamond
    // glyph to the terminal.
    try appendSanitizedUtf8(&buf, testing.allocator, "ok\xEF\xBF\xBDS");
    try testing.expectEqualStrings("okS", buf.items);
}

test "appendSanitizedUtf8: replaces truncated trailing lead byte" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Trailing 0xE2 with nothing after it — classic chunk-cut scenario.
    try appendSanitizedUtf8(&buf, testing.allocator, "ok\xE2");
    try testing.expectEqualStrings("ok?", buf.items);
}

test "safeUtf8Take: backs up through a 3-byte character" {
    // "世" is U+4E16, encoded as 0xE4 0xB8 0x96 (3 bytes).
    const s = "x世y";
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 1)); // "x"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 2)); // back up: "x"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 3)); // back up: "x"
    try testing.expectEqual(@as(usize, 4), safeUtf8Take(s, 4)); // "x世"
    try testing.expectEqual(@as(usize, 5), safeUtf8Take(s, 5)); // "x世y"
}

test "makeLine/appendLine: round-trips text into owned storage" {
    var history: std.ArrayList(Line) = .empty;
    defer {
        for (history.items) |*l| l.text.deinit(testing.allocator);
        history.deinit(testing.allocator);
    }

    try appendLine(&history, testing.allocator, .user, "hi");
    try appendLine(&history, testing.allocator, .agent, "hello");

    try testing.expectEqual(@as(usize, 2), history.items.len);
    try testing.expectEqualStrings("hi", history.items[0].text.items);
    try testing.expectEqualStrings("hello", history.items[1].text.items);
}

test "AgentList.findOrAppend: dedupes and returns stable indexes" {
    var list = AgentList.init(testing.allocator);
    defer list.deinit();

    const a = try list.findOrAppend("tiger");
    const b = try list.findOrAppend("claw");
    const c = try list.findOrAppend("tiger");
    try testing.expectEqual(@as(usize, 0), a);
    try testing.expectEqual(@as(usize, 1), b);
    try testing.expectEqual(@as(usize, 0), c);
    try testing.expectEqual(@as(usize, 2), list.count());
}

test "visualWidth: counts codepoints, not bytes" {
    try testing.expectEqual(@as(usize, 3), visualWidth("abc"));
    // Single-cell box-drawing glyph "─" is 3 bytes in UTF-8.
    try testing.expectEqual(@as(usize, 1), visualWidth("─"));
    try testing.expectEqual(@as(usize, 5), visualWidth("a─b─c"));
}
