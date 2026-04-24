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

pub fn init(allocator: std.mem.Allocator, agent_name: []const u8) Root {
    return .{
        .allocator = allocator,
        .header = .{
            .agent_name = agent_name,
            .pending = false,
            .spinner_tick = 0,
        },
        .input = Input.init(allocator),
    };
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
    // Append the typed text as a user line. The runner
    // integration that fires a turn in response lands in a
    // follow-up; for now Enter is just visible feedback.
    self.appendLine(.user, text) catch {};
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
        .init => ctx.redraw = true,
        else => {},
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
