//! Per-tool result preview formatters.
//!
//! Each tool gets a tailored one-block preview the TUI's existing
//! `turn_tool_done` rendering surfaces in the history pane. The
//! reference frontier-coder UIs render bash/read with bespoke vxfw
//! widgets; we keep things in plain text for now because the
//! existing tigerclaw history widget renders text uniformly. The
//! `ansi.zig` helper here lets path mentions be clickable on
//! supporting terminals.
//!
//! Adding a vxfw widget per tool is a follow-up — the shape this
//! module emits is the same shape such a widget would consume, so
//! the migration is a layout pass rather than a data-model rework.

const std = @import("std");
const agent_runner = @import("../harness/agent_runner.zig");
const ansi = @import("ansi.zig");

/// Cap on how many bytes we let the preview reach. Anything past
/// this gets truncated with a marker so the history pane doesn't
/// scroll a 32 KiB stdout block.
const MAX_PREVIEW_BYTES: usize = 4 * 1024;
/// Cap on rendered stdout lines for bash. Past this they collapse
/// to a "[N more lines]" footer.
const BASH_STDOUT_LINES: usize = 12;
/// Cap on rendered stderr lines for bash.
const BASH_STDERR_LINES: usize = 6;

pub fn render(
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: agent_runner.ToolFinishedKind,
) ![]u8 {
    return switch (kind) {
        .bash => |b| renderBash(allocator, b),
        .read => |r| renderRead(allocator, r),
        .glob => |g| renderGlob(allocator, g),
        .grep => |g| renderGrep(allocator, g),
        .web_search => |w| renderWebSearch(allocator, w),
        .todo_write => |t| renderTodo(allocator, t),
        .text => |t| renderGeneric(allocator, name, t),
        .cancelled => |t| allocator.dupe(u8, t),
    };
}

// ---------------------------------------------------------------------------
// bash

fn renderBash(allocator: std.mem.Allocator, b: agent_runner.BashFinished) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Section parser: the runner's adapter emits a fixed format we
    // re-shape into a friendlier preview.
    const stdout = sectionAfter(b.text, "--- stdout ---\n", "--- stderr ---\n");
    const stderr = sectionAfter(b.text, "--- stderr ---\n", null);

    const status_label: []const u8 = if (b.interrupted)
        "interrupted"
    else if (b.exit_code == 0)
        "ok"
    else
        "fail";

    const status_line = try std.fmt.allocPrint(
        allocator,
        "{s}  exit {d}  {d} ms\n",
        .{ status_label, b.exit_code, b.duration_ms },
    );
    defer allocator.free(status_line);
    try out.appendSlice(allocator, status_line);

    if (stdout.len > 0) {
        try out.appendSlice(allocator, "stdout:\n");
        try appendCappedLines(&out, allocator, stdout, BASH_STDOUT_LINES);
    }
    if (stderr.len > 0) {
        try out.appendSlice(allocator, "stderr:\n");
        try appendCappedLines(&out, allocator, stderr, BASH_STDERR_LINES);
    }
    if (stdout.len == 0 and stderr.len == 0) {
        try out.appendSlice(allocator, "(no output)\n");
    }

    return capPreview(&out, allocator);
}

fn sectionAfter(text: []const u8, marker: []const u8, end_marker: ?[]const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, marker) orelse return "";
    const start = at + marker.len;
    const end = if (end_marker) |em|
        if (std.mem.indexOfPos(u8, text, start, em)) |e| e else text.len
    else
        text.len;
    return std.mem.trimEnd(u8, text[start..end], "\n");
}

fn appendCappedLines(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    cap: usize,
) !void {
    var iter = std.mem.splitScalar(u8, body, '\n');
    var emitted: usize = 0;
    var total: usize = 0;
    while (iter.next()) |line| {
        total += 1;
        if (emitted < cap) {
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            emitted += 1;
        }
    }
    if (total > emitted) {
        const rendered = try std.fmt.allocPrint(allocator, "  [{d} more line(s)]\n", .{total - emitted});
        defer allocator.free(rendered);
        try out.appendSlice(allocator, rendered);
    }
}

// ---------------------------------------------------------------------------
// read

fn renderRead(allocator: std.mem.Allocator, r: agent_runner.ReadFinished) ![]u8 {
    return switch (r.variant) {
        .text => std.fmt.allocPrint(allocator, "Read {d} line(s)", .{linesIn(r.text)}),
        .unchanged => allocator.dupe(u8, "Unchanged since last read"),
        .empty => allocator.dupe(u8, "(empty file)"),
        .past_eof => allocator.dupe(u8, r.text),
    };
}

fn linesIn(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var n: u32 = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    if (s[s.len - 1] == '\n') n -= 1;
    return n;
}

// ---------------------------------------------------------------------------
// glob

fn renderGlob(allocator: std.mem.Allocator, g: agent_runner.GlobFinished) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const lines = countNewlines(g.text);
    const file_count = if (lines >= 1 and std.mem.indexOf(u8, g.text, "[no matches]") == null) lines else 0;

    const header = try std.fmt.allocPrint(
        allocator,
        "Matched {d} file(s)\n",
        .{file_count},
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    try appendCappedLines(&out, allocator, std.mem.trimEnd(u8, g.text, "\n"), 8);
    return capPreview(&out, allocator);
}

// ---------------------------------------------------------------------------
// grep

fn renderGrep(allocator: std.mem.Allocator, g: agent_runner.GrepFinished) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "grep results:\n");
    try appendCappedLines(&out, allocator, std.mem.trimEnd(u8, g.text, "\n"), 12);
    return capPreview(&out, allocator);
}

// ---------------------------------------------------------------------------
// web_search

fn renderWebSearch(allocator: std.mem.Allocator, w: agent_runner.WebSearchFinished) ![]u8 {
    return capPreviewSlice(allocator, w.text);
}

// ---------------------------------------------------------------------------
// todo_write
//
// Renders a checklist with status icons. The runner stores the live
// list on the LiveAgentRunner, but the preview only sees the summary
// line; the model already received the structured list. We do best-
// effort: parse the summary numbers and emit a compact pill.

fn renderTodo(allocator: std.mem.Allocator, t: agent_runner.TodoWriteFinished) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}",
        .{t.text},
    );
}

/// Render an explicit list of todo items as a checklist. Used by
/// callers that have access to the runner's todo state directly.
pub fn renderTodoChecklist(
    allocator: std.mem.Allocator,
    items: []const TodoChecklistItem,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (items) |item| {
        const icon: []const u8 = switch (item.status) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .done => "[x]",
        };
        const display = if (item.status == .in_progress)
            (item.active_form orelse item.title)
        else
            item.title;
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, icon);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, display);
        try out.append(allocator, '\n');
    }
    if (items.len == 0) {
        try out.appendSlice(allocator, "  (no items)\n");
    }
    return capPreview(&out, allocator);
}

pub const TodoChecklistItem = struct {
    title: []const u8,
    active_form: ?[]const u8 = null,
    status: enum { pending, in_progress, done } = .pending,
};

// ---------------------------------------------------------------------------
// generic / fallback

fn renderGeneric(allocator: std.mem.Allocator, name: []const u8, text: []const u8) ![]u8 {
    _ = name;
    return capPreviewSlice(allocator, text);
}

fn capPreviewSlice(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= MAX_PREVIEW_BYTES) return allocator.dupe(u8, text);
    const marker = "\n[output truncated]";
    const out = try allocator.alloc(u8, MAX_PREVIEW_BYTES + marker.len);
    @memcpy(out[0..MAX_PREVIEW_BYTES], text[0..MAX_PREVIEW_BYTES]);
    @memcpy(out[MAX_PREVIEW_BYTES..], marker);
    return out;
}

fn capPreview(out: *std.ArrayList(u8), allocator: std.mem.Allocator) ![]u8 {
    if (out.items.len <= MAX_PREVIEW_BYTES) return out.toOwnedSlice(allocator);
    const marker = "\n[output truncated]";
    const final = try allocator.alloc(u8, MAX_PREVIEW_BYTES + marker.len);
    @memcpy(final[0..MAX_PREVIEW_BYTES], out.items[0..MAX_PREVIEW_BYTES]);
    @memcpy(final[MAX_PREVIEW_BYTES..], marker);
    out.deinit(allocator);
    return final;
}

fn countNewlines(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "renderBash: shapes stdout/stderr into a compact pill" {
    const input =
        "exit_code: 0\nduration_ms: 142\ninterrupted: false\n" ++
        "--- stdout ---\nOn branch main\nnothing to commit\n" ++
        "--- stderr ---\n\n";
    const out = try renderBash(testing.allocator, .{
        .text = input,
        .exit_code = 0,
        .interrupted = false,
        .duration_ms = 142,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "ok") != null);
    try testing.expect(std.mem.indexOf(u8, out, "exit 0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "On branch main") != null);
}

test "renderBash: interrupted shows the marker" {
    const out = try renderBash(testing.allocator, .{
        .text = "exit_code: -1\n",
        .exit_code = -1,
        .interrupted = true,
        .duration_ms = 100,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "interrupted") != null);
}

test "renderBash: empty stdout/stderr renders \"(no output)\"" {
    const out = try renderBash(testing.allocator, .{
        .text = "exit_code: 0\nduration_ms: 5\ninterrupted: false\n",
        .exit_code = 0,
        .interrupted = false,
        .duration_ms = 5,
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(no output)") != null);
}

test "renderRead: text variant" {
    const out = try renderRead(testing.allocator, .{
        .text = "     1\u{2192}line one\n     2\u{2192}line two",
        .variant = .text,
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Read 2 line(s)", out);
}

test "renderRead: unchanged variant" {
    const out = try renderRead(testing.allocator, .{ .text = "...", .variant = .unchanged });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Unchanged since last read", out);
}

test "renderRead: empty variant" {
    const out = try renderRead(testing.allocator, .{ .text = "...", .variant = .empty });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(empty file)", out);
}

test "renderTodoChecklist: status icons" {
    const items = [_]TodoChecklistItem{
        .{ .title = "first", .status = .done },
        .{ .title = "doing it", .active_form = "Doing it now", .status = .in_progress },
        .{ .title = "later", .status = .pending },
    };
    const out = try renderTodoChecklist(testing.allocator, &items);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[x] first") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[~] Doing it now") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[ ] later") != null);
}

test "renderTodoChecklist: empty list shows placeholder" {
    const out = try renderTodoChecklist(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(no items)") != null);
}

test "render: dispatches per kind" {
    const out = try render(testing.allocator, "glob", .{ .glob = .{ .text = "src/main.zig\nsrc/lib.zig\n" } });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Matched 2") != null);
}

test "render: text fallback passes through" {
    const out = try render(testing.allocator, "fetch_url", .{ .text = "hello" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}
