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

const Root = @This();

// --- state ---
allocator: std.mem.Allocator,
header: Header,
/// Heap-allocated chat history. Owned by the Root widget; freed
/// on deinit. Lines are appended by the event handler in
/// response to key presses and runner events. The History
/// widget borrows a slice of this list per frame.
history: std.ArrayList(tui.Line) = .empty,

pub fn init(allocator: std.mem.Allocator, agent_name: []const u8) Root {
    return .{
        .allocator = allocator,
        .header = .{
            .agent_name = agent_name,
            .pending = false,
            .spinner_tick = 0,
        },
    };
}

pub fn deinit(self: *Root) void {
    for (self.history.items) |*l| {
        l.text.deinit(self.allocator);
        l.deinitSpans(self.allocator);
        l.deinitToolId(self.allocator);
    }
    self.history.deinit(self.allocator);
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
    _ = ptr;
    switch (event) {
        .key_press => |key| {
            // Ctrl-C / Ctrl-Q / lowercase q all quit.
            if (key.matches('c', .{ .ctrl = true }) or
                key.matches('q', .{ .ctrl = true }) or
                key.matches('q', .{}))
            {
                ctx.quit = true;
                return;
            }
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

    // Root surface spans the full terminal. Two children:
    //   [0] HeaderWidget  — top 2 rows
    //   [1] HistoryWidget — between header and the bottom footer
    // The input box + picker lands in a follow-up; for now the
    // history pane runs to the bottom of the screen.
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    const surface = try vxfw.Surface.initWithChildren(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
        children,
    );

    // Header.
    const header_surface = try self.header.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = width, .height = 2 },
    ));
    surface.children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = header_surface,
        .z_index = 0,
    };

    // History. Starts at row 2, fills to the bottom of the pane.
    // Add a 1-cell side margin on each edge so lines don't kiss
    // the terminal border.
    const history_height: u16 = if (height > 2) height - 2 else 0;
    const history_width: u16 = if (width > 2) width - 2 else width;
    const history_view: History = .{ .lines = self.history.items };
    const history_surface = try history_view.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = history_width, .height = history_height },
    ));
    surface.children[1] = .{
        .origin = .{ .row = 2, .col = 1 },
        .surface = history_surface,
        .z_index = 0,
    };

    return surface;
}
