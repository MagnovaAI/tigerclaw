//! Root vxfw widget for the TUI.
//!
//! Owns every piece of TUI state and handles every event. The
//! outer `tui.run()` hands this widget to `vxfw.App.run`, which
//! drives the frame loop, event dispatch, and render cycle.
//!
//! This is the fulcrum of the App.run migration: the hand-rolled
//! event loop in the old tui.run() → gone, replaced by
//! `App.run(root.widget())`. Widget methods drive everything.
//!
//! Intermediate state: today the widget renders only a
//! `HeaderWidget`. The history, input box, agent picker, and
//! streaming sink routing are stubs that will land in follow-up
//! commits. Quit on `q` or Ctrl-C is wired so the app is testable
//! end-to-end right now.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");
const harness = @import("../../harness/root.zig");
const Header = @import("header.zig");
const History = @import("history.zig");
const Input = @import("input.zig");

const Root = @This();

// --- state ---
allocator: std.mem.Allocator,
header: Header,
/// Heap-allocated chat history. Owned by the Root widget; freed
/// on deinit. Lines are appended by the event handler in
/// response to key presses and runner events. The History
/// widget borrows a slice of this list per frame.
history: std.ArrayList(tui.Line) = .empty,
input: Input,
/// Borrowed runner. Set by \`attachRunner\` before \`App.run\`;
/// null during tests that don't spin up a real runner.
runner: ?*harness.AgentRunner = null,
/// Agent session id — normally the agent name. Reused across
/// turns so the context engine keeps continuity.
session_id: []const u8 = "tiger",
/// Borrowed App pointer. Used by worker-thread sinks to post
/// UserEvents back into the main loop via \`app.loop.?.postEvent\`.
app: ?*vxfw.App = null,
/// History index of the line currently being streamed into. Set
/// when a turn starts; reset on done/error.
pending_agent_line: ?usize = null,
/// Whether any text has been streamed into the pending agent
/// line yet. If the turn finishes with zero text (tool-only
/// reply, error mid-stream), we drop the empty placeholder.
pending_saw_text: bool = false,

pub fn init(allocator: std.mem.Allocator, agent_name: []const u8) Root {
    return .{
        .allocator = allocator,
        .header = .{
            .agent_name = agent_name,
            .pending = false,
            .spinner_tick = 0,
        },
        .input = Input.init(allocator),
        .session_id = agent_name,
    };
}

/// Wire the runner + app so submit actually fires a turn. Call
/// after \`init\` and before \`app.run(root.widget(), .{})\`.
pub fn attachRunner(self: *Root, runner: *harness.AgentRunner, app: *vxfw.App) void {
    self.runner = runner;
    self.app = app;
}

pub fn deinit(self: *Root) void {
    for (self.history.items) |*l| {
        l.text.deinit(self.allocator);
        l.deinitSpans(self.allocator);
        l.deinitToolId(self.allocator);
    }
    self.history.deinit(self.allocator);
    self.input.deinit();
}

/// Install the Input's submit callback. Called from runVxfw
/// after the Root is fully constructed — the callback captures
/// `&root` via opaque ctx so it can mutate history on Enter.
pub fn wireSubmit(self: *Root) void {
    self.input.on_submit = onSubmit;
    self.input.submit_ctx = self;
}

fn onSubmit(ctx: ?*anyopaque, text: []const u8) void {
    const self: *Root = @ptrCast(@alignCast(ctx.?));
    if (text.len == 0) return;
    // Don't start a second turn while one is in flight. The user
    // can type the next message — it'll just queue up as another
    // history line but the runner won't fire.
    if (self.header.pending) {
        self.appendLine(.user, text) catch {};
        return;
    }
    self.beginTurn(text) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "! could not start turn: {s}", .{@errorName(err)}) catch "! turn failed";
        self.appendLine(.system, msg) catch {};
    };
}

// --- Turn orchestration ----------------------------------------------------
//
// When the input fires \`on_submit\`, we append the user line,
// reserve an empty agent line, flip the spinner on, and spawn a
// worker thread that calls \`runner.run(...)\` with sinks that
// post UserEvents back into the App's main loop. The event
// handler consumes those UserEvents, mutating history in place.

/// Tag for the UserEvent payloads we post from worker threads.
/// Each variant carries owned heap-allocated slices — the main
/// loop frees them after handling. We match on event.app.name
/// to dispatch; the pointer data is cast to the matching
/// payload struct.
const ue_chunk = "tui.chunk";
const ue_tool_start = "tui.tool_start";
const ue_tool_done = "tui.tool_done";
const ue_done = "tui.done";
const ue_error = "tui.error";
const ue_tick = "tui.tick";

const ChunkPayload = struct { text: []u8 };
const ToolStartPayload = struct { id: []u8, name: []u8 };
const ToolDonePayload = struct { id: []u8, name: []u8, output: []u8 };
const ErrorPayload = struct { message: []u8 };

/// Context the worker thread carries. Allocated on heap;
/// worker frees on exit.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    app: *vxfw.App,
    message: []u8,
    session_id: []const u8,
};

fn beginTurn(self: *Root, typed: []const u8) !void {
    const runner = self.runner orelse return error.NoRunner;
    const app = self.app orelse return error.NoApp;

    try self.appendLine(.user, typed);
    // Reserve a placeholder agent line so streamed chunks have a
    // stable slot to accumulate into.
    const agent_line_idx = self.history.items.len;
    try self.appendLine(.agent, "");
    self.pending_agent_line = agent_line_idx;
    self.pending_saw_text = false;

    self.header.pending = true;

    // Dup the message so the worker owns it independent of the
    // input buffer (which clears right after on_submit returns).
    const message_copy = try self.allocator.dupe(u8, typed);
    errdefer self.allocator.free(message_copy);

    const ctx = try self.allocator.create(WorkerCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .root = self,
        .app = app,
        .message = message_copy,
        .session_id = self.session_id,
    };
    _ = runner;

    var thread = try std.Thread.spawn(.{}, workerMain, .{ctx});
    thread.detach();
}

fn workerMain(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.message);
        ctx.allocator.destroy(ctx);
    }

    const runner = ctx.root.runner orelse {
        postError(ctx, "no runner");
        postDone(ctx);
        return;
    };

    const result = runner.run(.{
        .session_id = ctx.session_id,
        .input = ctx.message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = @ptrCast(ctx),
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = @ptrCast(ctx),
    }) catch |err| {
        postError(ctx, @errorName(err));
        postDone(ctx);
        return;
    };
    _ = result;
    postDone(ctx);
}

// Runner sinks — run on the worker thread. Each one heap-
// allocates a payload struct, attaches it to a \`UserEvent\`, and
// posts to the main loop. The loop's event handler casts the
// pointer back and frees.

fn chunkSink(sink_ctx: ?*anyopaque, fragment: []const u8) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    const payload = ctx.allocator.create(ChunkPayload) catch return;
    payload.* = .{ .text = ctx.allocator.dupe(u8, fragment) catch {
        ctx.allocator.destroy(payload);
        return;
    } };
    postUserEvent(ctx, ue_chunk, payload);
}

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
            const payload = ctx.allocator.create(ToolStartPayload) catch return;
            payload.* = .{
                .id = ctx.allocator.dupe(u8, id) catch {
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, name) catch {
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
            };
            postUserEvent(ctx, ue_tool_start, payload);
        },
        .finished => {
            const payload = ctx.allocator.create(ToolDonePayload) catch return;
            payload.* = .{
                .id = ctx.allocator.dupe(u8, id) catch {
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, name) catch {
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .output = ctx.allocator.dupe(u8, output) catch {
                    ctx.allocator.free(payload.id);
                    ctx.allocator.free(payload.name);
                    ctx.allocator.destroy(payload);
                    return;
                },
            };
            postUserEvent(ctx, ue_tool_done, payload);
        },
    }
}

fn postError(ctx: *WorkerCtx, message: []const u8) void {
    const payload = ctx.allocator.create(ErrorPayload) catch return;
    payload.* = .{ .message = ctx.allocator.dupe(u8, message) catch {
        ctx.allocator.destroy(payload);
        return;
    } };
    postUserEvent(ctx, ue_error, payload);
}

fn postDone(ctx: *WorkerCtx) void {
    postUserEvent(ctx, ue_done, null);
}

fn postUserEvent(ctx: *WorkerCtx, name: []const u8, data: ?*const anyopaque) void {
    const loop = ctx.app.loop orelse {
        // App loop is gone — nothing we can do. Leak the payload;
        // the process is probably tearing down anyway.
        return;
    };
    loop.postEvent(.{ .app = .{ .name = name, .data = data } });
}

/// Append a plain text line to the history, taking ownership
/// of a heap-allocated copy of `text`. Used to seed demo data
/// while the runner integration is still in flight.
pub fn appendLine(self: *Root, role: tui.Line.Role, text: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, text);
    try self.history.append(self.allocator, .{
        .role = role,
        .text = buf,
    });
}

pub fn widget(self: *Root) vxfw.Widget {
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
    const self: *Root = @ptrCast(@alignCast(ptr));
    switch (event) {
        .key_press => |key| {
            // Hard-quit chord: Ctrl-C / Ctrl-Q. Plain `q`
            // no longer quits now that the input box is live —
            // it's a valid character to type in a message.
            if (key.matches('c', .{ .ctrl = true }) or
                key.matches('q', .{ .ctrl = true }))
            {
                ctx.quit = true;
                return;
            }
            // Everything else is forwarded to the input widget's
            // handler. vxfw's focus system would do this
            // automatically once we call `request_focus` — we're
            // manually bridging for now since Root is the only
            // widget receiving events.
            try self.input.widget().handleEvent(ctx, event);
        },
        .winsize => ctx.redraw = true,
        .init => {
            // Kick off the spinner tick loop so the header
            // spinner animates while a turn is pending.
            try ctx.tick(80, self.widget());
            ctx.redraw = true;
        },
        .tick => {
            if (self.header.pending) {
                self.header.spinner_tick +%= 1;
                ctx.redraw = true;
            }
            // Keep the tick chain alive so the spinner keeps
            // ticking as soon as pending flips back on.
            try ctx.tick(80, self.widget());
        },
        .app => |ue| try self.handleUserEvent(ctx, ue),
        else => {},
    }
}

fn handleUserEvent(self: *Root, ctx: *vxfw.EventContext, ue: vxfw.UserEvent) !void {
    if (std.mem.eql(u8, ue.name, ue_chunk)) {
        const p: *const ChunkPayload = @ptrCast(@alignCast(ue.data.?));
        defer self.allocator.free(p.text);
        defer self.allocator.destroy(@as(*ChunkPayload, @constCast(p)));

        if (self.pending_agent_line) |idx| {
            var line = &self.history.items[idx];
            try line.text.appendSlice(self.allocator, p.text);
            self.pending_saw_text = true;
        }
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_start)) {
        const p: *const ToolStartPayload = @ptrCast(@alignCast(ue.data.?));
        defer self.allocator.free(p.id);
        defer self.allocator.free(p.name);
        defer self.allocator.destroy(@as(*ToolStartPayload, @constCast(p)));

        // Append a pending tool line. We own the id so tool_done
        // can find its matching entry.
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        try text.appendSlice(self.allocator, p.name);
        try text.appendSlice(self.allocator, "   (pending)");

        const id_owned = try self.allocator.dupe(u8, p.id);
        errdefer self.allocator.free(id_owned);

        try self.history.append(self.allocator, .{
            .role = .tool,
            .text = text,
            .tool_id = id_owned,
        });
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_done)) {
        const p: *const ToolDonePayload = @ptrCast(@alignCast(ue.data.?));
        defer self.allocator.free(p.id);
        defer self.allocator.free(p.name);
        defer self.allocator.free(p.output);
        defer self.allocator.destroy(@as(*ToolDonePayload, @constCast(p)));

        // Walk history backwards, find the matching pending line
        // (by tool_id), promote it with the output preview.
        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.history.items[i];
            if (entry.role != .tool) continue;
            if (entry.tool_id) |id| {
                if (std.mem.eql(u8, id, p.id)) {
                    entry.text.clearRetainingCapacity();
                    try entry.text.appendSlice(self.allocator, p.name);
                    try entry.text.appendSlice(self.allocator, " → ");
                    const cap: usize = @min(p.output.len, 500);
                    try entry.text.appendSlice(self.allocator, p.output[0..cap]);
                    if (cap < p.output.len) try entry.text.appendSlice(self.allocator, "…");
                    entry.deinitToolId(self.allocator);
                    break;
                }
            }
        }
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_error)) {
        const p: *const ErrorPayload = @ptrCast(@alignCast(ue.data.?));
        defer self.allocator.free(p.message);
        defer self.allocator.destroy(@as(*ErrorPayload, @constCast(p)));

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "! turn failed: {s}", .{p.message}) catch "! turn failed";
        try self.appendLine(.system, line);
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_done)) {
        // Drop the empty placeholder if the turn produced no
        // text (e.g. a tool-only reply or an error mid-stream).
        if (!self.pending_saw_text) {
            if (self.pending_agent_line) |idx| {
                // Only drop if it's actually still the last-ish
                // line we reserved — inserting tool lines above
                // shifts the index forward but the placeholder
                // stays at the original idx.
                if (idx < self.history.items.len) {
                    var dropped = self.history.orderedRemove(idx);
                    dropped.text.deinit(self.allocator);
                    dropped.deinitSpans(self.allocator);
                    dropped.deinitToolId(self.allocator);
                }
            }
        }
        self.pending_agent_line = null;
        self.pending_saw_text = false;
        self.header.pending = false;
        ctx.redraw = true;
    }
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Root = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;

    // Layout (top → bottom):
    //   rows 0..1       header (2 rows)
    //   rows 2..h-4     history (remaining minus input)
    //   rows h-3..h-1   input box (3 rows: top border, text, bottom border)
    const header_rows: u16 = 2;
    const input_rows: u16 = 3;
    const history_rows: u16 = if (height > header_rows + input_rows) height - header_rows - input_rows else 0;

    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    const surface = try vxfw.Surface.initWithChildren(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
        children,
    );

    // Header.
    const header_surface = try self.header.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = width, .height = header_rows },
    ));
    surface.children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = header_surface,
        .z_index = 0,
    };

    // History with 1-cell side margin.
    const history_width: u16 = if (width > 2) width - 2 else width;
    const history_view: History = .{ .lines = self.history.items };
    const history_surface = try history_view.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = history_width, .height = history_rows },
    ));
    surface.children[1] = .{
        .origin = .{ .row = @intCast(header_rows), .col = 1 },
        .surface = history_surface,
        .z_index = 0,
    };

    // Input at the bottom. Full width; the widget draws its own
    // border.
    const input_surface = try self.input.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = width, .height = input_rows },
    ));
    surface.children[2] = .{
        .origin = .{ .row = @intCast(height - input_rows), .col = 0 },
        .surface = input_surface,
        .z_index = 0,
    };

    return surface;
}
