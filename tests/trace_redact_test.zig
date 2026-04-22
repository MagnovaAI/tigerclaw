//! Integration: record spans with secret-bearing attributes, replay
//! them, rewrite via redact, and summarise via tool_use_summary.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const trace = tigerclaw.trace;

const testing = std.testing;

test "redact + summary: end-to-end round trip strips secrets and totals calls" {
    const envelope = trace.Envelope{
        .trace_id = "r",
        .run_id = "run",
        .started_at_ns = 0,
        .mode = .run,
    };

    const original_spans = [_]trace.Span{
        .{ .id = "root", .trace_id = "r", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 100 },
        .{
            .id = "t1",
            .parent_id = "root",
            .trace_id = "r",
            .kind = .tool_call,
            .name = "chat",
            .started_at_ns = 10,
            .finished_at_ns = 20,
            .attributes_json = "{\"anthropic_api_key\":\"sk-live-xyz\",\"model\":\"opus\"}",
        },
        .{
            .id = "t2",
            .parent_id = "root",
            .trace_id = "r",
            .kind = .tool_call,
            .name = "chat",
            .started_at_ns = 21,
            .finished_at_ns = 25,
            .status = .err,
            .attributes_json = "{\"anthropic_api_key\":\"sk-live-xyz\",\"model\":\"opus\"}",
        },
        .{
            .id = "t3",
            .parent_id = "root",
            .trace_id = "r",
            .kind = .tool_call,
            .name = "read",
            .started_at_ns = 30,
            .finished_at_ns = 32,
        },
    };

    var b = trace.fixture.Builder.init(testing.allocator);
    defer b.deinit();
    try b.writeEnvelope(envelope);
    for (original_spans) |s| try b.append(s);

    const bytes = try b.toOwnedBytes(testing.allocator);
    defer testing.allocator.free(bytes);

    var replay = try trace.replayer.replayFromBytes(testing.allocator, bytes);
    defer replay.deinit();

    // Every span with attributes_json: redact. Verify no secret leaks.
    for (replay.spans) |s| {
        const r = try trace.redact.redactSpan(testing.allocator, s);
        defer trace.redact.freeRedactedSpan(testing.allocator, s, r);

        if (r.attributes_json) |attrs| {
            try testing.expect(std.mem.indexOf(u8, attrs, "sk-live-xyz") == null);
            try testing.expect(std.mem.indexOf(u8, attrs, "\"***\"") != null);
            try testing.expect(std.mem.indexOf(u8, attrs, "\"model\":\"opus\"") != null);
        }
    }

    // Summary: 3 tool calls across 2 unique names, chat=2 (1 ok + 1 err),
    // read=1 (ok). "chat" tops the list because count 2 > 1.
    const summary = try trace.tool_use_summary.summarize(testing.allocator, replay.spans);
    defer summary.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), summary.totalCalls());
    try testing.expectEqual(@as(usize, 2), summary.entries.len);
    try testing.expectEqualStrings("chat", summary.entries[0].name);
    try testing.expectEqual(@as(u32, 2), summary.entries[0].count);
    try testing.expectEqual(@as(u32, 1), summary.entries[0].ok);
    try testing.expectEqual(@as(u32, 1), summary.entries[0].err);
    try testing.expectEqualStrings("read", summary.entries[1].name);
}
