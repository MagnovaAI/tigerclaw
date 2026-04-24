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
const Header = @import("header.zig");

const Root = @This();

// --- state ---
allocator: std.mem.Allocator,
header: Header,

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

    // Root surface spans the full terminal; we composite children
    // as SubSurfaces below.
    const surface = try vxfw.Surface.initWithChildren(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
        try ctx.arena.alloc(vxfw.SubSurface, 1),
    );

    // Header: top two rows, full width.
    const header_surface = try self.header.widget().draw(ctx.withConstraints(
        .{ .width = 0, .height = 0 },
        .{ .width = width, .height = 2 },
    ));
    surface.children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = header_surface,
        .z_index = 0,
    };

    return surface;
}
