//! Integration: write a trace through the recorder + fixture Builder,
//! read it back through the replayer, and assert structural equality.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const trace = tigerclaw.trace;

const testing = std.testing;

test "roundtrip: envelope + three spans survive write → read" {
    const envelope = trace.Envelope{
        .trace_id = "rt-1",
        .run_id = "run-rt-1",
        .started_at_ns = 1_700_000_000_000_000_000,
        .mode = .run,
        .dataset_hash = .{ .hex = "abcd" },
    };

    const spans = [_]trace.Span{
        .{ .id = "root", .trace_id = "rt-1", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 100 },
        .{ .id = "turn-1", .parent_id = "root", .trace_id = "rt-1", .kind = .turn, .name = "turn-1", .started_at_ns = 10, .finished_at_ns = 80 },
        .{ .id = "tool-a", .parent_id = "turn-1", .trace_id = "rt-1", .kind = .tool_call, .name = "read", .started_at_ns = 20, .finished_at_ns = 25 },
    };

    var builder = trace.fixture.Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.writeEnvelope(envelope);
    for (spans) |s| try builder.append(s);

    const bytes = try builder.toOwnedBytes(testing.allocator);
    defer testing.allocator.free(bytes);

    var replay = try trace.replayer.replayFromBytes(testing.allocator, bytes);
    defer replay.deinit();

    try testing.expectEqual(trace.schema_version, replay.envelope.schema_version);
    try testing.expectEqualStrings(envelope.trace_id, replay.envelope.trace_id);
    try testing.expectEqualStrings("abcd", replay.envelope.dataset_hash.hex);

    try testing.expectEqual(spans.len, replay.spans.len);
    for (spans, 0..) |want, i| {
        const got = replay.spans[i];
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.started_at_ns, got.started_at_ns);
        try testing.expectEqual(want.finished_at_ns.?, got.finished_at_ns.?);
    }
}

test "roundtrip: open span survives (finished_at_ns stays null)" {
    const envelope = trace.Envelope{ .trace_id = "rt-2", .run_id = "r", .started_at_ns = 0, .mode = .run };

    var builder = trace.fixture.Builder.init(testing.allocator);
    defer builder.deinit();

    try builder.writeEnvelope(envelope);
    try builder.append(.{
        .id = "open",
        .trace_id = "rt-2",
        .kind = .turn,
        .name = "open-turn",
        .started_at_ns = 1,
    });

    const bytes = try builder.toOwnedBytes(testing.allocator);
    defer testing.allocator.free(bytes);

    var replay = try trace.replayer.replayFromBytes(testing.allocator, bytes);
    defer replay.deinit();

    try testing.expectEqual(@as(usize, 1), replay.spans.len);
    try testing.expect(replay.spans[0].finished_at_ns == null);
    try testing.expect(replay.spans[0].isOpen());
}
