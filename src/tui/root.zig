//! Full-screen chat TUI.
//!
//! Launched by `tigerclaw` (no subcommand). Connects to a locally
//! running gateway on 127.0.0.1:8765 and presents a single-agent
//! chat loop — message history scrolls above, text input below.
//!
//! # Design
//!
//! * Built on libvaxis (vendored in packages/vaxis).
//! * Event-driven — vaxis's Loop pushes key presses, resize, and
//!   focus events into a queue; we switch on them.
//! * Send is synchronous: Enter blocks the UI on the HTTP round-trip
//!   to the gateway. A spinner/async send is a follow-up.
//! * History is a plain ArrayList of owned strings. No scrolling yet
//!   — overflow just falls off the top.
//!
//! # Gateway contract
//!
//! POST /sessions/<agent>/turns with {"message": "..."} expects back
//! {"output": "..."} — this is what `renderJsonFromOutput` in
//! gateway/routes.zig emits when the client doesn't request SSE.

const std = @import("std");
const vaxis = @import("vaxis");
const http_client = @import("../cli/commands/http_client.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

const Line = struct {
    role: Role,
    text: []u8,

    const Role = enum { user, agent, system };
};

pub const Options = struct {
    base_url: []const u8 = "http://127.0.0.1:8765",
    agent: []const u8 = "tiger",
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

    var loop: vaxis.Loop(Event) = .{ .vaxis = &vx, .tty = &tty };
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
        for (history.items) |l| allocator.free(l.text);
        history.deinit(allocator);
    }

    // Greeting line so the pane isn't empty on launch.
    try appendLine(&history, allocator, .system, "connected to gateway. Ctrl-C to quit.");

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
                    return;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    const typed = try currentInput(allocator, &input);
                    defer allocator.free(typed);
                    if (typed.len == 0) continue;
                    // Push the user line, clear the input, then fire
                    // the turn. The reply appends a new line to
                    // history once it lands.
                    const user_copy = try allocator.dupe(u8, typed);
                    try history.append(allocator, .{ .role = .user, .text = user_copy });
                    input.clearAndFree();

                    // Render once so the user's line shows before
                    // the synchronous HTTP call blocks.
                    try draw(&vx, &input, history.items, opts.agent);
                    try vx.render(writer);
                    try writer.flush();

                    const reply = sendTurn(allocator, io, opts, typed) catch |err| blk: {
                        const msg = std.fmt.allocPrint(allocator, "! gateway error: {s}", .{@errorName(err)}) catch
                            break :blk try allocator.dupe(u8, "! gateway error");
                        break :blk msg;
                    };
                    try history.append(allocator, .{ .role = .agent, .text = reply });
                } else {
                    try input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(allocator, writer, ws),
            else => {},
        }

        try draw(&vx, &input, history.items, opts.agent);
        try vx.render(writer);
        try writer.flush();
    }
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

fn appendLine(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    role: Line.Role,
    text: []const u8,
) !void {
    const owned = try allocator.dupe(u8, text);
    try history.append(allocator, .{ .role = role, .text = owned });
}

fn draw(
    vx: *vaxis.Vaxis,
    input: *vaxis.widgets.TextInput,
    history: []const Line,
    agent_name: []const u8,
) !void {
    const win = vx.window();
    win.clear();

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " tigerclaw · {s} ", .{agent_name}) catch " tigerclaw ";
    _ = win.printSegment(
        .{ .text = title, .style = .{ .bold = true } },
        .{ .row_offset = 0, .col_offset = 0 },
    );

    const history_height_i: i32 = @as(i32, @intCast(win.height)) - 3;
    if (history_height_i > 0) {
        const pane = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = win.width,
            .height = @intCast(history_height_i),
        });
        drawHistory(pane, history);
    }

    if (win.height >= 3) {
        const input_child = win.child(.{
            .x_off = 0,
            .y_off = @intCast(@as(i32, @intCast(win.height)) - 3),
            .width = win.width,
            .height = 3,
            .border = .{ .where = .all },
        });
        input.draw(input_child);
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
            .user => "> ",
            .agent => "< ",
            .system => "· ",
        };

        const width: usize = @intCast(pane.width);
        const avail = if (width > prefix.len) width - prefix.len else 1;

        // Count wrapped rows for this message.
        var rows_needed: usize = 1;
        var remaining = line.text;
        if (remaining.len > avail) {
            rows_needed = (remaining.len + avail - 1) / avail;
        }
        if (rows_needed > 32) rows_needed = 32; // safety cap

        var start_row = row_cursor - @as(i32, @intCast(rows_needed - 1));
        if (start_row < 0) {
            // Partial render: drop leading rows that fall off-screen.
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
            .user => .{ .fg = .{ .index = 14 } },
            .agent => .{},
            .system => .{ .fg = .{ .index = 8 } },
        };

        var row = start_row;
        _ = pane.printSegment(
            .{ .text = prefix, .style = style },
            .{ .row_offset = @intCast(row), .col_offset = 0 },
        );

        var col_offset: usize = prefix.len;
        while (remaining.len > 0 and row < pane.height) {
            const take = @min(remaining.len, avail);
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

/// Synchronous POST to the gateway; returns an owned slice with the
/// agent's reply text. Caller frees.
fn sendTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    message: []const u8,
) ![]u8 {
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/sessions/{s}/turns", .{ opts.base_url, opts.agent });

    const body_json = try std.json.Stringify.valueAlloc(allocator, .{
        .agent = opts.agent,
        .message = message,
    }, .{});
    defer allocator.free(body_json);

    var resp_buf: std.Io.Writer.Allocating = .init(allocator);
    defer resp_buf.deinit();

    _ = try http_client.send(
        allocator,
        io,
        .{
            .method = .POST,
            .url = url,
            .json_body = body_json,
            // Plain JSON reply — renderJsonFromOutput in
            // gateway/routes.zig gives us {"output": "..."}.
        },
        &resp_buf.writer,
        .{},
    );

    const raw = resp_buf.written();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return try std.fmt.allocPrint(allocator, "! malformed response: {s}", .{raw});
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try std.fmt.allocPrint(allocator, "! unexpected JSON: {s}", .{raw});
    }
    const out_v = parsed.value.object.get("output") orelse {
        return try std.fmt.allocPrint(allocator, "! no output field: {s}", .{raw});
    };
    if (out_v != .string) {
        return try std.fmt.allocPrint(allocator, "! output not string: {s}", .{raw});
    }
    return try allocator.dupe(u8, out_v.string);
}
