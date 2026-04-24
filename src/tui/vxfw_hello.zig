//! Minimal vxfw smoke test.
//!
//! Launches a vxfw `App` showing a single `FlexColumn` with three
//! `Text` children. Lets us verify the vxfw subset we ported (in
//! `packages/vaxis/src/vxfw/`) actually runs end-to-end against a
//! real TTY before committing to migrating the production TUI onto
//! it. Invoke via `tigerclaw vxfw-hello`.
//!
//! If this smoke test works, the vxfw runtime, layout solver, and
//! ANSI output are all healthy on 0.16. If it doesn't work, we have
//! a bounded thing to debug before touching the main TUI.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Press 'q' or Ctrl-C to quit. We attach a tiny root widget that
/// listens for those keys and flips the app's quit flag.
const RootWidget = struct {
    text_a: vxfw.Text,
    text_b: vxfw.Text,
    text_c: vxfw.Text,
    items: [3]vxfw.FlexItem,
    col: vxfw.FlexColumn,

    fn init(self: *RootWidget) void {
        self.text_a = .{
            .text = "tigerclaw vxfw smoke test — press q to quit",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }, .bold = true },
        };
        self.text_b = .{
            .text = "if you can read this, vxfw is working on your terminal.",
            .style = .{ .fg = .{ .rgb = .{ 0xF5, 0xE6, 0xD3 } } },
        };
        self.text_c = .{
            .text = "— tiger",
            .style = .{ .fg = .{ .rgb = .{ 0xFF, 0xC8, 0x57 } }, .italic = true },
        };
        self.items = .{
            .{ .widget = self.text_a.widget(), .flex = 0 },
            .{ .widget = self.text_b.widget(), .flex = 0 },
            .{ .widget = self.text_c.widget(), .flex = 1 },
        };
        self.col = .{ .children = &self.items };
    }

    fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = eventHandler,
            .drawFn = drawFn,
        };
    }

    fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ptr;
        switch (event) {
            .key_press => |k| {
                // 'q' or Ctrl-C quits.
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
            },
            else => {},
        }
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        // Delegate straight to the FlexColumn — the root widget is
        // just a thin event handler that quits on q/Ctrl-C. The
        // actual layout is the column.
        return self.col.widget().draw(ctx);
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var app = try vxfw.App.init(allocator, io);
    defer app.deinit();

    var root: RootWidget = undefined;
    root.init();

    try app.run(root.widget(), .{});
}
