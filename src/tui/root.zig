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
const vxfw = vaxis.vxfw;
const md = @import("md.zig");
const live_runner = @import("../cli/commands/live_runner.zig");
const harness = @import("../harness/root.zig");

test {
    // Ensure md tests are discovered when the unit-test binary
    // walks references from this file.
    std.testing.refAllDecls(md);
    // Force body compilation of every vxfw widget in the subset
    // we plan to migrate onto, so any 0.16 API regression in
    // packages/vaxis/src/vxfw surfaces here at build time instead
    // of blowing up mid-refactor.
    _ = &vxfw.App.init;
    _ = &vxfw.App.run;
    _ = &vxfw.FlexColumn.draw;
    _ = &vxfw.Text.draw;
    _ = &vxfw.Border.draw;
    _ = &vxfw.Padding.draw;
    _ = &vxfw.Spinner.draw;
    // Pull the vxfw smoke test's public fn into the compile graph
    // too, so any widget wiring we add there surfaces at build time.
    _ = &@import("vxfw_hello.zig").run;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// One decoded SSE chunk frame. Slice is heap-allocated on the
    /// worker thread; the main loop takes ownership and frees after
    /// appending to history.
    turn_chunk: []u8,
    /// A tool call is about to run. Both slices are heap-allocated
    /// and owned by the main loop after receipt.
    turn_tool_start: ToolStartPayload,
    /// A tool call completed. All slices heap-allocated + owned.
    turn_tool_done: ToolDonePayload,
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

const ToolStartPayload = struct { id: []u8, name: []u8 };
const ToolDonePayload = struct { id: []u8, name: []u8, output: []u8 };

const Line = struct {
    role: Role,
    text: std.ArrayList(u8),
    /// Style spans over `text`. Non-null only for agent replies
    /// that have finished streaming and been re-parsed as
    /// markdown; streaming in progress keeps this null so the
    /// renderer falls back to a flat style.
    spans: ?[]md.Span = null,
    /// Set on `tool` lines only — the Anthropic tool-call id the
    /// line represents. `turn_tool_done` uses this to find its
    /// matching pending line and promote it to the done state
    /// without having to pattern-match on rendered text.
    tool_id: ?[]u8 = null,

    fn deinitSpans(self: *Line, allocator: std.mem.Allocator) void {
        if (self.spans) |s| {
            allocator.free(s);
            self.spans = null;
        }
    }

    fn deinitToolId(self: *Line, allocator: std.mem.Allocator) void {
        if (self.tool_id) |id| {
            allocator.free(id);
            self.tool_id = null;
        }
    }

    const Role = enum { user, agent, system, tool };
};

pub const Options = struct {
    agent: []const u8 = "tiger",
    /// Caller-resolved `$HOME`. The TUI instantiates a
    /// `LiveAgentRunner` in-process against this root so there is no
    /// gateway daemon to launch or port to bind; every turn flows
    /// straight from the provider through the runner's streaming
    /// sinks into the vaxis event queue.
    home: []const u8 = "",
};

const EventLoop = vaxis.Loop(Event);

/// Tiger palette — warm amber + black-stripe charcoal + cream on
/// black, inspired by a Bengal tiger's coat. 24-bit truecolor; the
/// terminal needs `COLORTERM=truecolor` (default on iTerm2, Ghostty,
/// WezTerm, Kitty, modern Terminal.app). On a non-truecolor term the
/// sequences gracefully degrade to the nearest 256-color index.
const palette = struct {
    // Core tiger colours — reused as field values in Style below. Kept
    // in one block so tweaking the theme means editing nine numbers,
    // not nine separate Style entries.
    const orange: vaxis.Color = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }; // tiger orange
    const amber: vaxis.Color = .{ .rgb = .{ 0xD9, 0x6A, 0x00 } }; // deep amber
    const cream: vaxis.Color = .{ .rgb = .{ 0xF5, 0xE6, 0xD3 } }; // warm cream
    const gold: vaxis.Color = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }; // hot gold
    const green: vaxis.Color = .{ .rgb = .{ 0x6B, 0xAF, 0x58 } }; // jungle green
    const stripe: vaxis.Color = .{ .rgb = .{ 0x1A, 0x12, 0x10 } }; // charcoal stripe
    const smoke: vaxis.Color = .{ .rgb = .{ 0x6B, 0x5E, 0x56 } }; // smoke gray
    const ember: vaxis.Color = .{ .rgb = .{ 0xE8, 0x60, 0x3C } }; // ember red
    const moss: vaxis.Color = .{ .rgb = .{ 0x4A, 0x6B, 0x40 } }; // moss dim
    const code_bg: vaxis.Color = .{ .rgb = .{ 0x2A, 0x1F, 0x1A } }; // inline-code background

    const title: vaxis.Style = .{ .fg = stripe, .bg = orange, .bold = true };
    const agent_chip: vaxis.Style = .{ .fg = stripe, .bg = gold, .bold = true };
    const status_idle: vaxis.Style = .{ .fg = green, .bold = true };
    const status_busy: vaxis.Style = .{ .fg = amber, .bold = true };
    const separator: vaxis.Style = .{ .fg = smoke };
    const user: vaxis.Style = .{ .fg = gold, .bold = true };
    const agent: vaxis.Style = .{ .fg = cream };
    const system: vaxis.Style = .{ .fg = smoke, .italic = true };
    /// Tool-call trace lines. Dim moss — enough to read but clearly
    /// subordinate to the user/agent conversation.
    const tool: vaxis.Style = .{ .fg = moss, .italic = true };
    const prompt: vaxis.Style = .{ .fg = orange, .bold = true };
    const hint: vaxis.Style = .{ .fg = smoke, .italic = true };
    const picker_border: vaxis.Style = .{ .fg = orange };
    const picker_item: vaxis.Style = .{ .fg = cream };
    const picker_item_selected: vaxis.Style = .{ .fg = stripe, .bg = orange, .bold = true };

    // Markdown span overlays. Each function composes the span style
    // on top of the caller's base style (typically `palette.agent`)
    // so text still reads as the speaker's line colour with the
    // markdown flavour applied on top.
    fn mdStyle(base: vaxis.Style, kind: md.StyleKind) vaxis.Style {
        var s = base;
        switch (kind) {
            .plain => {},
            .bold => s.bold = true,
            .italic => s.italic = true,
            .code => {
                s.fg = gold;
                s.bg = code_bg;
            },
            .link => {
                s.fg = orange;
                s.ul_style = .single;
            },
            .heading => {
                s.fg = orange;
                s.bold = true;
            },
            .block_quote => s.fg = smoke,
        }
        return s;
    }
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
    // Switch to the legacy SGR encoding (semicolon-separated sub-
    // parameters) so truecolor paints on macOS Terminal.app. The
    // default is `.standard` — colon-separated, per ITU-T T.416 —
    // which Terminal.app silently drops on the floor. iTerm2 /
    // Ghostty / WezTerm accept both; the legacy form is the
    // universally-compatible one. (See packages/vaxis/src/ctlseqs.zig
    // — `fg_rgb` vs `fg_rgb_legacy`.)
    vx.sgr = .legacy;
    vx.caps.rgb = true;

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
        for (history.items) |*l| {
            l.text.deinit(allocator);
            l.deinitSpans(allocator);
            l.deinitToolId(allocator);
        }
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

    // Load the in-process runner for the default agent. The TUI owns
    // this lifecycle; swapping agents tears the runner down and
    // rebuilds it so each agent sees its own system prompt, model
    // config, and workspace sandbox. If the initial load fails
    // (missing config.json, unknown provider) we surface the error
    // to the user and exit so they can fix it — the TUI can't do
    // useful work without a runner.
    var live = live_runner.LiveAgentRunner.load(allocator, io, agents.name(selected), "", opts.home) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "tigerclaw tui: could not load agent '{s}': {s}\n", .{ agents.name(selected), @errorName(err) });
        defer allocator.free(msg);
        _ = std.c.write(2, msg.ptr, msg.len);
        return err;
    };
    defer live.deinit();
    var agent_runner: harness.AgentRunner = live.runner();
    // Agent-switching via Ctrl-N / Ctrl-P / picker is still wired to
    // `selected` for display purposes, but the in-process runner is
    // pinned to the agent it was loaded with. Hot-reload on switch
    // is future work; for now the user has to restart the TUI to
    // change agents. Silence the never-mutated warning — a later
    // commit will mutate this when reload lands.
    _ = &agent_runner;

    try appendAgentLine(&history, allocator, agents.items(), selected);

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
                    const before = selected;
                    handlePickerKey(key, &picker_open, &picker_cursor, &selected, agents.items());
                    if (selected != before) {
                        try appendAgentLine(&history, allocator, agents.items(), selected);
                    }
                } else if (key.matches('e', .{ .ctrl = true }) and !pending) {
                    picker_cursor = selected;
                    picker_open = true;
                } else if (key.matches('n', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = (selected + 1) % agents.count();
                    try appendAgentLine(&history, allocator, agents.items(), selected);
                } else if (key.matches('p', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = if (selected == 0) agents.count() - 1 else selected - 1;
                    try appendAgentLine(&history, allocator, agents.items(), selected);
                } else if (key.matches(vaxis.Key.enter, .{}) and !pending) {
                    const typed = try currentInput(allocator, &input);
                    defer allocator.free(typed);
                    if (typed.len == 0) continue;

                    // Slash-command interception — keeps the wire
                    // path (agent_line + worker spawn) reserved for
                    // actual agent turns. Leading whitespace is
                    // trimmed first so stray spaces from paste or
                    // accidental keystrokes still activate the
                    // command parser instead of being sent on to
                    // the agent as user text.
                    const trimmed = std.mem.trim(u8, typed, " \t");
                    if (std.mem.startsWith(u8, trimmed, "/")) {
                        input.clearAndFree();
                        try handleSlashCommand(
                            &history,
                            allocator,
                            &agents,
                            &selected,
                            trimmed,
                        );
                        continue;
                    }

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
                    // Use the agent's name as the session id so the
                    // runner's context engine keyed per-session still
                    // sees continuous history across turns. Swapping
                    // agents starts a new session naturally.
                    ctx.* = .{
                        .allocator = allocator,
                        .io = io,
                        .loop = &loop,
                        .runner = &agent_runner,
                        .session_id = agents.name(selected),
                        .message = message_copy,
                    };
                    const t = std.Thread.spawn(.{}, workerMain, .{ctx}) catch |err| {
                        allocator.free(message_copy);
                        allocator.destroy(ctx);
                        if (pending_agent_line) |idx| {
                            var dropped = history.orderedRemove(idx);
                            dropped.text.deinit(allocator);
                            dropped.deinitSpans(allocator);
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
            .turn_tool_start => |ts| {
                // Append a dim "pending" line before the next chunk
                // lands. The line's `tool_id` is held so
                // `turn_tool_done` can promote it in place.
                defer allocator.free(ts.name);
                errdefer allocator.free(ts.id);

                var text: std.ArrayList(u8) = .empty;
                errdefer text.deinit(allocator);
                // Role prefix (`↻ `) is added by drawHistory; the
                // payload only carries the tool name + status.
                try text.appendSlice(allocator, ts.name);
                try text.appendSlice(allocator, "   (pending)");

                try history.append(allocator, .{
                    .role = .tool,
                    .text = text,
                    .tool_id = ts.id,
                });
            },
            .turn_tool_done => |td| {
                defer allocator.free(td.id);
                defer allocator.free(td.name);
                defer allocator.free(td.output);

                // Find the most recent matching pending tool line.
                // Walking backwards keeps the cost tiny in practice
                // (the pending line is normally the last thing we
                // appended before this event fires).
                var match_idx: ?usize = null;
                var i: usize = history.items.len;
                while (i > 0) {
                    i -= 1;
                    const entry = &history.items[i];
                    if (entry.role != .tool) continue;
                    if (entry.tool_id) |id| {
                        if (std.mem.eql(u8, id, td.id)) {
                            match_idx = i;
                            break;
                        }
                    }
                }

                if (match_idx) |idx| {
                    var line = &history.items[idx];
                    line.text.clearRetainingCapacity();
                    try line.text.appendSlice(allocator, td.name);
                    try line.text.appendSlice(allocator, " \u{2192} ");
                    // Cap preview at 500 display columns (~5 wrapped
                    // rows on a narrow terminal, one on a wide one) —
                    // enough to see the shape of a fetch result or a
                    // read_file without a noisy tool hijacking the
                    // chat scroll. Full output is still in the
                    // agent's conversation context. \`takeCols\`
                    // walks by display columns so we don't cut a
                    // codepoint in half.
                    const max_preview: usize = 500;
                    const taken = takeCols(td.output, max_preview);
                    try line.text.appendSlice(allocator, td.output[0..taken.bytes]);
                    if (taken.bytes < td.output.len) try line.text.appendSlice(allocator, "\u{2026}");
                    line.deinitToolId(allocator);
                }
            },
            .turn_done => {
                if (!pending_saw_text) {
                    if (pending_agent_line) |idx| {
                        var dropped = history.orderedRemove(idx);
                        dropped.text.deinit(allocator);
                        dropped.deinitSpans(allocator);
                    }
                } else if (pending_agent_line) |idx| {
                    // Streaming done — re-parse the accumulated raw
                    // markdown with koino and attach the span list so
                    // the renderer paints bold/italic/code/etc. Guard
                    // against two failure modes silently losing the
                    // reply: parser error (fall through), and the
                    // walker returning empty text for a non-empty
                    // source (keep the raw bytes unchanged, skip
                    // styling). Either is better than an empty
                    // agent line with no explanation.
                    var line = &history.items[idx];
                    const had_text = line.text.items.len > 0;
                    if (md.render(allocator, line.text.items)) |rendered| {
                        if (rendered.text.len > 0 or !had_text) {
                            line.text.clearRetainingCapacity();
                            line.text.appendSlice(allocator, rendered.text) catch {};
                            line.deinitSpans(allocator);
                            line.spans = rendered.spans;
                            allocator.free(rendered.text);
                        } else {
                            // Parser returned nothing for non-empty
                            // input — keep the raw bytes and drop
                            // the (empty) spans slice.
                            allocator.free(rendered.text);
                            allocator.free(rendered.spans);
                        }
                    } else |_| {}
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
                        dropped.deinitSpans(allocator);
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
    // Wipe the cell buffer before every draw. Without this, cells from
    // a prior frame linger wherever the current draw does not paint
    // over them — which surfaces as the trailing `Z��` / `��8` junk
    // in the row above the input box when a streamed reply ends and
    // the old bytes are what's left in the grid.
    vx.window().clear();
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

/// Push a one-line system banner naming the active agent. Used on
/// boot and whenever the operator flips to a different agent via
/// `Ctrl-N` / `Ctrl-P` / `/agent <name>`.
fn appendAgentLine(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    agents: []const []const u8,
    selected: usize,
) !void {
    const name = if (agents.len == 0) "default" else agents[selected];
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "agent: {s}", .{name}) catch "agent: ?";
    try appendLine(history, allocator, .system, text);
}

/// Dispatch a slash-command line. Recognised commands:
///   /agent              — list agents with a marker on the active one
///   /agent <name>       — switch to the named agent (must already be loaded)
///   /agents             — alias for `/agent`
///   /help               — short reminder of available commands
/// Unknown commands echo a one-line error. No command ever errors out
/// of the event loop; they always write a system line and return.
fn handleSlashCommand(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    agents: *AgentList,
    selected: *usize,
    line: []const u8,
) !void {
    // Trim the leading slash. Split on the first run of whitespace.
    const body = std.mem.trim(u8, line[1..], " \t");
    var tok_it = std.mem.tokenizeAny(u8, body, " \t");
    const cmd = tok_it.next() orelse {
        try appendLine(history, allocator, .system, "commands: /agent [name], /agents, /help");
        return;
    };

    if (std.mem.eql(u8, cmd, "help")) {
        try appendLine(history, allocator, .system, "commands: /agent [name], /agents, /help");
        return;
    }

    if (std.mem.eql(u8, cmd, "agent") or std.mem.eql(u8, cmd, "agents")) {
        const target = tok_it.next();
        if (target == null) {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll("agents:") catch {};
            for (agents.items(), 0..) |n, i| {
                const marker: []const u8 = if (i == selected.*) " *" else "  ";
                w.print(" {s}{s}", .{ marker, n }) catch {};
            }
            try appendLine(history, allocator, .system, w.buffered());
            return;
        }

        const want = target.?;
        for (agents.items(), 0..) |n, i| {
            if (std.mem.eql(u8, n, want)) {
                selected.* = i;
                try appendAgentLine(history, allocator, agents.items(), selected.*);
                return;
            }
        }

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "no such agent: {s}", .{want}) catch "no such agent";
        try appendLine(history, allocator, .system, msg);
        return;
    }

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: /{s}  (try /help)", .{cmd}) catch "unknown command";
    try appendLine(history, allocator, .system, msg);
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

    // Status-hint row intentionally omitted: it produced glyph
    // artefacts on macOS Terminal at narrow widths that I could not
    // fully attribute to a single source (printSegment wrap, width
    // detection races, or a terminal-response byte bleeding through
    // the input path). The header already shows the agent chip and
    // ready/thinking state, which covers the common case. Keybindings
    // are documented in tigerclaw --help.

    if (win.height >= 3) {
        // Orange-bordered input box so the prompt stands out against
        // the dim-smoke history scroll. A tiger-striped prompt glyph
        // sits at the left edge; placeholder text appears when the
        // buffer is empty so new users know what the box is for.
        const input_child = win.child(.{
            .x_off = 0,
            .y_off = @intCast(@as(i32, @intCast(win.height)) - 3),
            .width = win.width,
            .height = 3,
            .border = .{ .where = .all, .style = .{ .fg = palette.orange } },
        });
        _ = input_child.printSegment(
            .{ .text = "❯ ", .style = palette.prompt },
            .{ .row_offset = 0, .col_offset = 0 },
        );
        const input_inner = input_child.child(.{
            .x_off = 2,
            .y_off = 0,
            .width = if (input_child.width > 2) input_child.width - 2 else 1,
            .height = 1,
        });
        // Paint placeholder first when the buffer is empty, so the
        // input widget's subsequent draw only paints the cursor cell
        // (1 col) — leaving the placeholder text visible under it.
        const input_empty = input.buf.firstHalf().len + input.buf.secondHalf().len == 0;
        if (input_empty) {
            _ = input_inner.printSegment(
                .{ .text = "message the tiger…", .style = palette.hint },
                .{ .row_offset = 0, .col_offset = 1 },
            );
        }
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
    // Left: title. Kept ASCII-only — the previous emoji-prefixed
    // version triggered grapheme-width races on some terminals
    // that corrupted the right-side chip area during rapid
    // pending→ready transitions.
    _ = win.printSegment(
        .{ .text = "  tigerclaw  ", .style = palette.title },
        .{ .row_offset = 0, .col_offset = 0 },
    );

    // Right: agent chip + status chip, right-justified.
    var chip_buf: [128]u8 = undefined;
    const agent_name = if (agents.len > 0) agents[selected] else "—";
    const chip = std.fmt.bufPrint(&chip_buf, " {s} ", .{agent_name}) catch " agent ";

    const spinner = spinner_frames[@intCast(spinner_tick % spinner_frames.len)];
    var status_buf: [64]u8 = undefined;
    // Pad both labels to the same display width so the transition
    // from "thinking" → "ready" doesn't leave stale cells past the
    // right edge of the shorter string. vaxis's differential render
    // sometimes decides a cell's unchanged when the style flips back
    // and forth, which leaves the trailing "ng" of "thinking" bleeding
    // into "ready ". Same width in both states = no residue.
    const status_text = if (pending)
        (std.fmt.bufPrint(&status_buf, " {s} thinking ", .{spinner}) catch " … ")
    else
        " ● ready    ";

    const chip_len: usize = measureCols(chip);
    const status_len: usize = measureCols(status_text);
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

    // Separator rule: left quarter in tiger orange, rest in smoke.
    // The coloured prefix echoes the title badge and gives the
    // header some visual weight without dominating the chat scroll.
    if (win.height > 1 and win.width > 0) {
        const accent_cols: u16 = @min(@as(u16, @intCast(win.width)), 18);
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            const style: vaxis.Style = if (col < accent_cols)
                .{ .fg = palette.orange }
            else
                palette.separator;
            _ = win.printSegment(
                .{ .text = "━", .style = style },
                .{ .row_offset = 1, .col_offset = col },
            );
        }
    }
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

/// Walk `bytes` codepoint by codepoint, accumulating display columns
/// via vaxis's `gwidth` table. Stop just before exceeding `max_cols`.
/// Returns the byte count and the column count consumed.
///
/// This is what you want for terminal layout — `safeUtf8Take` caps on
/// bytes, which for multi-byte chars (emoji, em-dash) overshoots the
/// visible width and causes wrapped-row overlap. Callers should use
/// the `bytes` return for slicing and the `cols` return if they
/// track remaining row space.
fn takeCols(bytes: []const u8, max_cols: usize) struct { bytes: usize, cols: usize } {
    if (max_cols == 0) return .{ .bytes = 0, .cols = 0 };
    var i: usize = 0;
    var cols: usize = 0;
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
            1;
        if (i + seq_len > bytes.len) break;
        const w: usize = @intCast(vaxis.gwidth.gwidth(bytes[i .. i + seq_len], .unicode));
        if (cols + w > max_cols) break;
        cols += w;
        i += seq_len;
    }
    return .{ .bytes = i, .cols = cols };
}

/// Sum the total display columns across every byte of `bytes`. Used
/// to compute how many terminal rows a history line will need when
/// word-wrapped to a given column budget.
fn measureCols(bytes: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
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
        // Speaker glyphs — single-cell Unicode only. The previous
        // agent prefix `🐯 ` was a wide emoji (2 display cells) that
        // triggered grapheme-width races on some macOS terminals
        // during streaming redraws — lines got painted partially and
        // looked like empty prefixes. Switched to the `✦` star glyph
        // (1 cell, warm amber in context) so the agent still reads
        // distinctly without the width hazard.
        const prefix = switch (line.role) {
            .user => "❯ ",
            .agent => "✦ ",
            .system => "∙ ",
            .tool => "↻ ",
        };

        const width: usize = @intCast(pane.width);
        // Prefix width in *display columns*, not bytes. Emoji glyphs
        // (e.g. the agent's 🐯) are 4 bytes but ~2 display cells, so
        // using \`prefix.len\` here would over-estimate by 2 cells
        // per emoji prefix and throw every wrap calculation off.
        const prefix_cols: usize = measureCols(prefix);
        const avail = if (width > prefix_cols) width - prefix_cols else 1;

        // Rows needed is driven by *display columns* and counts
        // embedded newlines as explicit row breaks. Each line
        // segment between newlines contributes ceil(cols / avail)
        // rows. Without this, markdown lists / tool output
        // containing \\n get painted with the newline interpreted
        // mid-row, scrambling the display.
        var rows_needed: usize = 0;
        var seg_it = std.mem.splitScalar(u8, line.text.items, '\n');
        while (seg_it.next()) |seg| {
            const seg_cols = measureCols(seg);
            const seg_rows: usize = if (seg_cols == 0) 1 else (seg_cols + avail - 1) / avail;
            rows_needed += seg_rows;
        }
        if (rows_needed == 0) rows_needed = 1;
        if (rows_needed > 32) rows_needed = 32;

        var remaining = line.text.items;
        var start_row = row_cursor - @as(i32, @intCast(rows_needed - 1));
        if (start_row < 0) {
            const drop = @as(usize, @intCast(-start_row));
            if (drop >= rows_needed) {
                row_cursor -= @intCast(rows_needed);
                continue;
            }
            // Skip `drop` rows worth of columns off the front of the
            // line. Walk by columns, not bytes, so multi-byte chars
            // don't trigger the same sizing bug here.
            var cols_to_skip: usize = drop * avail;
            while (cols_to_skip > 0 and remaining.len > 0) {
                const taken = takeCols(remaining, cols_to_skip);
                if (taken.bytes == 0) break;
                remaining = remaining[taken.bytes..];
                cols_to_skip -= taken.cols;
                if (taken.cols == 0) break;
            }
            rows_needed -= drop;
            start_row = 0;
        }

        const base_style: vaxis.Style = switch (line.role) {
            .user => palette.user,
            .agent => palette.agent,
            .system => palette.system,
            .tool => palette.tool,
        };

        var row = start_row;
        _ = pane.printSegment(
            .{ .text = prefix, .style = base_style },
            .{ .row_offset = @intCast(row), .col_offset = 0 },
        );

        // Track the byte offset of `remaining[0]` back into the full
        // line.text buffer so we can look up which markdown span
        // covers each byte as we paint. `drop` accounted for rows
        // that fell off the top of the pane when row_cursor < 0.
        const total_len = line.text.items.len;
        const span_offset_start: usize = total_len - remaining.len;

        var col_offset: usize = prefix_cols;
        while (remaining.len > 0 and row < pane.height) {
            // Hard-wrap on embedded newlines: if the next segment
            // contains `\n`, stop at it, paint what's before, and
            // move the row cursor forward. Without this, we'd paint
            // `abc\ndef` as one segment and the terminal would
            // interpret the `\n` mid-row, jumping the cursor and
            // scrambling subsequent rows.
            const nl_pos: ?usize = std.mem.indexOfScalar(u8, remaining, '\n');
            const limit = if (nl_pos) |p| p else remaining.len;
            const slice = remaining[0..limit];

            // Then soft-wrap on display columns within the limit.
            const taken = takeCols(slice, avail);
            const take = if (taken.bytes == 0) safeUtf8Take(slice, 1) else taken.bytes;
            paintRow(
                pane,
                @intCast(row),
                @intCast(col_offset),
                remaining[0..take],
                span_offset_start + (remaining.ptr - line.text.items.ptr),
                base_style,
                line.spans,
            );
            remaining = remaining[take..];
            // Consume the newline itself if we stopped at one and
            // didn't also consume all the visible bytes on that row.
            if (remaining.len > 0 and remaining[0] == '\n') {
                remaining = remaining[1..];
            }
            row += 1;
            col_offset = prefix_cols;
        }

        row_cursor -= @intCast(rows_needed);
    }
}

/// Paint one row of wrapped text, applying per-byte markdown span
/// styles. Walks the slice in runs of constant style and emits one
/// `printSegment` per run.
fn paintRow(
    pane: vaxis.Window,
    row: u16,
    col_offset: u16,
    bytes: []const u8,
    bytes_start_in_line: usize,
    base_style: vaxis.Style,
    spans: ?[]md.Span,
) void {
    if (spans == null or spans.?.len == 0) {
        _ = pane.printSegment(
            .{ .text = bytes, .style = base_style },
            .{ .row_offset = row, .col_offset = col_offset },
        );
        return;
    }
    const all_spans = spans.?;

    var i: usize = 0;
    var col = col_offset;
    while (i < bytes.len) {
        const abs = bytes_start_in_line + i;
        const style = pickStyle(abs, base_style, all_spans);

        // Extend `j` while the style at byte `j` matches `style`.
        var j = i + 1;
        while (j < bytes.len and styleEql(pickStyle(bytes_start_in_line + j, base_style, all_spans), style)) : (j += 1) {}

        const slice = bytes[i..j];
        _ = pane.printSegment(
            .{ .text = slice, .style = style },
            .{ .row_offset = row, .col_offset = col },
        );
        // Advance column by *display width*, not byte count — a
        // styled span containing emoji used to over-advance and
        // push following spans off the right edge of the row.
        col += @intCast(measureCols(slice));
        i = j;
    }
}

/// Pick the style for byte `abs` in the full line: the innermost
/// covering span's style overlaid on `base`, or `base` alone.
fn pickStyle(abs: usize, base: vaxis.Style, spans: []md.Span) vaxis.Style {
    var s = base;
    for (spans) |sp| {
        if (abs >= sp.start and abs < sp.start + sp.len) {
            s = palette.mdStyle(s, sp.style);
        }
    }
    return s;
}

fn styleEql(a: vaxis.Style, b: vaxis.Style) bool {
    return std.meta.eql(a, b);
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
    /// Borrowed reference to the TUI's in-process runner. Shared
    /// across every worker turn on the same agent; swapped out on
    /// agent switch (see `reloadRunner`). Not owned here.
    runner: *harness.AgentRunner,
    session_id: []const u8,
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
            "! turn failed: {s}",
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
    // No gateway round-trip: call the runner directly and let the
    // sinks post events onto the vaxis loop as the provider streams.
    // The runner still fires `stream_sink` per text delta and
    // `tool_event_sink` on each tool-dispatch boundary.
    const result = ctx.runner.run(.{
        .session_id = ctx.session_id,
        .input = ctx.message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = @ptrCast(ctx),
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = @ptrCast(ctx),
    }) catch |err| {
        const name = @errorName(err);
        const msg = try std.fmt.allocPrint(ctx.allocator, "runner: {s}", .{name});
        ctx.loop.postEvent(.{ .turn_error = msg });
        return;
    };
    _ = result;
}

/// Sink adapter: each text fragment from the provider becomes one
/// `turn_chunk` event on the vaxis loop. The fragment is duped
/// because the runner borrows it across the callback only.
fn chunkSink(sink_ctx: ?*anyopaque, fragment: []const u8) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    const owned = ctx.allocator.dupe(u8, fragment) catch return;
    ctx.loop.postEvent(.{ .turn_chunk = owned });
}

/// Sink adapter for tool-dispatch boundaries. Both phases produce
/// owned slices so the main loop can free them after handling.
fn toolEventSink(
    sink_ctx: ?*anyopaque,
    phase: harness.agent_runner.ToolEventPhase,
    id: []const u8,
    name: []const u8,
    output: []const u8,
) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    switch (phase) {
        .started => {
            const id_owned = ctx.allocator.dupe(u8, id) catch return;
            errdefer ctx.allocator.free(id_owned);
            const name_owned = ctx.allocator.dupe(u8, name) catch return;
            ctx.loop.postEvent(.{ .turn_tool_start = .{ .id = id_owned, .name = name_owned } });
        },
        .finished => {
            const id_owned = ctx.allocator.dupe(u8, id) catch return;
            errdefer ctx.allocator.free(id_owned);
            const name_owned = ctx.allocator.dupe(u8, name) catch return;
            errdefer ctx.allocator.free(name_owned);
            const output_owned = ctx.allocator.dupe(u8, output) catch return;
            ctx.loop.postEvent(.{ .turn_tool_done = .{
                .id = id_owned,
                .name = name_owned,
                .output = output_owned,
            } });
        },
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
