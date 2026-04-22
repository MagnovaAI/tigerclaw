//! Render a trace to a compact human-readable form.
//!
//! The exporter is a convenience for CLI output and test assertions; it
//! is not part of the trust boundary. Each span renders as one line:
//!
//!   [kind] name  parent=<id>  status=<s>  dur=<ns>
//!
//! Indentation is inferred from parent depth (up to a cap to keep lines
//! readable).

const std = @import("std");
const schema = @import("schema.zig");
const span_mod = @import("span.zig");

const Writer = std.Io.Writer;
const max_depth = 8;

pub fn renderEnvelope(w: *Writer, envelope: schema.Envelope) Writer.Error!void {
    try w.print(
        "trace {s} run={s} mode={s} schema=v{d}\n",
        .{ envelope.trace_id, envelope.run_id, @tagName(envelope.mode), envelope.schema_version },
    );
}

pub fn renderSpan(
    w: *Writer,
    s: span_mod.Span,
    depth: usize,
) Writer.Error!void {
    const pad = @min(depth, max_depth);
    var i: usize = 0;
    while (i < pad) : (i += 1) try w.writeAll("  ");

    const dur = s.durationNs();
    try w.print(
        "[{s}] {s}  status={s}",
        .{ @tagName(s.kind), s.name, @tagName(s.status) },
    );
    if (dur) |d| {
        try w.print("  dur={d}ns", .{d});
    } else {
        try w.writeAll("  dur=?");
    }
    try w.writeByte('\n');
}

/// Writes envelope + every span in order, using `parent_id` to compute
/// indentation depth via a small lookup table.
pub fn render(
    w: *Writer,
    envelope: schema.Envelope,
    spans: []const span_mod.Span,
) Writer.Error!void {
    try renderEnvelope(w, envelope);

    // Build a dense id → depth map. Spans may reference parents that
    // come earlier in the stream; we honour that order.
    for (spans) |s| {
        const depth = depthOf(s, spans);
        try renderSpan(w, s, depth);
    }
}

fn depthOf(s: span_mod.Span, spans: []const span_mod.Span) usize {
    var depth: usize = 0;
    var current = s.parent_id;
    while (current) |pid| {
        var found = false;
        for (spans) |candidate| {
            if (!std.mem.eql(u8, candidate.id, pid)) continue;
            depth += 1;
            current = candidate.parent_id;
            found = true;
            break;
        }
        if (!found) break;
        if (depth > max_depth * 4) break; // defensive against cycles
    }
    return depth;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn renderToAlloc(
    allocator: std.mem.Allocator,
    envelope: schema.Envelope,
    spans: []const span_mod.Span,
) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try render(&aw.writer, envelope, spans);
    return try allocator.dupe(u8, aw.writer.buffered());
}

test "renderEnvelope emits a single-line summary" {
    const envelope = schema.Envelope{
        .trace_id = "T",
        .run_id = "R",
        .started_at_ns = 0,
        .mode = .bench,
    };
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderEnvelope(&aw.writer, envelope);
    const line = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, line, "trace T") != null);
    try testing.expect(std.mem.indexOf(u8, line, "mode=bench") != null);
    try testing.expect(std.mem.indexOf(u8, line, "schema=v2") != null);
}

test "render: nested spans get progressively indented" {
    const envelope = schema.Envelope{
        .trace_id = "T",
        .run_id = "R",
        .started_at_ns = 0,
        .mode = .run,
    };
    const spans = [_]span_mod.Span{
        .{ .id = "a", .trace_id = "T", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 10 },
        .{ .id = "b", .parent_id = "a", .trace_id = "T", .kind = .turn, .name = "turn-1", .started_at_ns = 1, .finished_at_ns = 5 },
        .{ .id = "c", .parent_id = "b", .trace_id = "T", .kind = .tool_call, .name = "read", .started_at_ns = 2, .finished_at_ns = 3 },
    };

    const text = try renderToAlloc(testing.allocator, envelope, &spans);
    defer testing.allocator.free(text);

    // "root" has no parent → depth 0 → no leading spaces.
    try testing.expect(std.mem.indexOf(u8, text, "\n[root] root") != null);
    // "turn-1" depth 1 → two leading spaces.
    try testing.expect(std.mem.indexOf(u8, text, "\n  [turn] turn-1") != null);
    // "read" depth 2 → four leading spaces.
    try testing.expect(std.mem.indexOf(u8, text, "\n    [tool_call] read") != null);
}

test "render: open spans show dur=?" {
    const envelope = schema.Envelope{ .trace_id = "T", .run_id = "R", .started_at_ns = 0, .mode = .run };
    const spans = [_]span_mod.Span{.{
        .id = "x",
        .trace_id = "T",
        .kind = .turn,
        .name = "open-turn",
        .started_at_ns = 0,
    }};
    const text = try renderToAlloc(testing.allocator, envelope, &spans);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "dur=?") != null);
}
