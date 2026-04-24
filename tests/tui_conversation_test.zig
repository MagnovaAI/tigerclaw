//! Conversation-flow tests for the vxfw RootWidget.
//!
//! Drives the widget's UserEvent handler directly — no real App,
//! no runner, no network. We construct the payloads a worker
//! thread would post and assert the history shape after the
//! handler runs. That pins the two invariants that regressed in
//! development:
//!
//!   1. Lines land in the order their events arrived. Chunks
//!      before a tool call stay *above* the tool line; chunks
//!      after it land on a *new* agent line *below*.
//!   2. The handler owns the payload lifetime. Every create/free
//!      in the test matches the handler's expectations — if the
//!      handler ever regresses to e.g. double-freeing, the test
//!      leak-detector catches it.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const vaxis = @import("vaxis");
const testing = std.testing;

const Root = tigerclaw.tui.widgets.root;
const vxfw = vaxis.vxfw;

/// Build an empty EventContext suitable for driving the handler
/// in-process. The handler writes to `ctx.redraw` and may push
/// commands — we don't care about either for history assertions.
fn makeCtx(allocator: std.mem.Allocator) vxfw.EventContext {
    return .{
        .alloc = allocator,
        .phase = .at_target,
        .cmds = .empty,
    };
}

fn postChunk(root: *Root, ctx: *vxfw.EventContext, text: []const u8) !void {
    const payload = try root.allocator.create(Root.ChunkPayload);
    payload.* = .{ .text = try root.allocator.dupe(u8, text) };
    try root.handleUserEvent(ctx, .{ .name = Root.ue_chunk, .data = payload });
}

fn postToolStart(root: *Root, ctx: *vxfw.EventContext, id: []const u8, name: []const u8) !void {
    const payload = try root.allocator.create(Root.ToolStartPayload);
    payload.* = .{
        .id = try root.allocator.dupe(u8, id),
        .name = try root.allocator.dupe(u8, name),
    };
    try root.handleUserEvent(ctx, .{ .name = Root.ue_tool_start, .data = payload });
}

fn postToolDone(root: *Root, ctx: *vxfw.EventContext, id: []const u8, name: []const u8, output: []const u8) !void {
    const payload = try root.allocator.create(Root.ToolDonePayload);
    payload.* = .{
        .id = try root.allocator.dupe(u8, id),
        .name = try root.allocator.dupe(u8, name),
        .output = try root.allocator.dupe(u8, output),
    };
    try root.handleUserEvent(ctx, .{ .name = Root.ue_tool_done, .data = payload });
}

fn postDone(root: *Root, ctx: *vxfw.EventContext) !void {
    try root.handleUserEvent(ctx, .{ .name = Root.ue_done, .data = null });
}

test "tui: chunk-only turn appends a single agent line" {
    var root = Root.init(testing.allocator, "tiger");
    defer root.deinit();

    var ctx = makeCtx(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);

    try postChunk(&root, &ctx, "Hello");
    try postChunk(&root, &ctx, " world");
    try postDone(&root, &ctx);

    try testing.expectEqual(@as(usize, 1), root.history.items.len);
    const line = root.history.items[0];
    try testing.expectEqual(tigerclaw.tui.Line.Role.agent, line.role);
    try testing.expectEqualStrings("Hello world", line.text.items);
}

test "tui: chunks around a tool call land on separate agent lines in order" {
    var root = Root.init(testing.allocator, "tiger");
    defer root.deinit();

    var ctx = makeCtx(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);

    // Pre-tool chunk, tool call, post-tool chunk.
    try postChunk(&root, &ctx, "Let me check…");
    try postToolStart(&root, &ctx, "toolu_1", "get_current_time");
    try postToolDone(&root, &ctx, "toolu_1", "get_current_time", "2026-04-24T16:00:00Z");
    try postChunk(&root, &ctx, "It's 4pm UTC.");
    try postDone(&root, &ctx);

    // Expected: 3 lines — agent, tool, agent.
    try testing.expectEqual(@as(usize, 3), root.history.items.len);

    try testing.expectEqual(tigerclaw.tui.Line.Role.agent, root.history.items[0].role);
    try testing.expectEqualStrings("Let me check…", root.history.items[0].text.items);

    try testing.expectEqual(tigerclaw.tui.Line.Role.tool, root.history.items[1].role);
    // Tool-done line's text format: "<name> → <output preview>"
    try testing.expect(std.mem.startsWith(u8, root.history.items[1].text.items, "get_current_time"));
    try testing.expect(std.mem.indexOf(u8, root.history.items[1].text.items, "2026-04-24T16:00:00Z") != null);

    try testing.expectEqual(tigerclaw.tui.Line.Role.agent, root.history.items[2].role);
    try testing.expectEqualStrings("It's 4pm UTC.", root.history.items[2].text.items);
}

test "tui: tool-done without a matching pending line is a noop" {
    // Tool-done landing before its tool-start (shouldn't happen
    // in practice, but handler must not crash).
    var root = Root.init(testing.allocator, "tiger");
    defer root.deinit();

    var ctx = makeCtx(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);

    try postToolDone(&root, &ctx, "toolu_missing", "zzz", "nope");
    try postDone(&root, &ctx);

    try testing.expectEqual(@as(usize, 0), root.history.items.len);
}

test "tui: two tool calls in a row each get their own line" {
    var root = Root.init(testing.allocator, "tiger");
    defer root.deinit();

    var ctx = makeCtx(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);

    try postToolStart(&root, &ctx, "a", "get_current_time");
    try postToolDone(&root, &ctx, "a", "get_current_time", "T1");
    try postToolStart(&root, &ctx, "b", "get_current_time");
    try postToolDone(&root, &ctx, "b", "get_current_time", "T2");
    try postChunk(&root, &ctx, "done");
    try postDone(&root, &ctx);

    try testing.expectEqual(@as(usize, 3), root.history.items.len);
    try testing.expectEqual(tigerclaw.tui.Line.Role.tool, root.history.items[0].role);
    try testing.expect(std.mem.indexOf(u8, root.history.items[0].text.items, "T1") != null);
    try testing.expectEqual(tigerclaw.tui.Line.Role.tool, root.history.items[1].role);
    try testing.expect(std.mem.indexOf(u8, root.history.items[1].text.items, "T2") != null);
    try testing.expectEqual(tigerclaw.tui.Line.Role.agent, root.history.items[2].role);
    try testing.expectEqualStrings("done", root.history.items[2].text.items);
}

test "tui: empty turn (done with no chunks and no tools) leaves history empty" {
    var root = Root.init(testing.allocator, "tiger");
    defer root.deinit();

    var ctx = makeCtx(testing.allocator);
    defer ctx.cmds.deinit(testing.allocator);

    try postDone(&root, &ctx);
    try testing.expectEqual(@as(usize, 0), root.history.items.len);
}
