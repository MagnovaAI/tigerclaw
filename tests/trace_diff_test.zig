//! Integration: diff two traces that were each produced by the recorder.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const trace = tigerclaw.trace;

const testing = std.testing;

fn writeTrace(allocator: std.mem.Allocator, spans: []const trace.Span) ![]u8 {
    const envelope = trace.Envelope{
        .trace_id = "d",
        .run_id = "r",
        .started_at_ns = 0,
        .mode = .run,
    };

    var b = trace.fixture.Builder.init(allocator);
    defer b.deinit();
    try b.writeEnvelope(envelope);
    for (spans) |s| try b.append(s);

    return try b.toOwnedBytes(allocator);
}

test "diff: replay of recorded trace matches itself" {
    const spans = [_]trace.Span{
        .{ .id = "a", .trace_id = "d", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 5 },
        .{ .id = "b", .parent_id = "a", .trace_id = "d", .kind = .turn, .name = "turn-1", .started_at_ns = 1, .finished_at_ns = 4 },
    };

    const bytes = try writeTrace(testing.allocator, &spans);
    defer testing.allocator.free(bytes);

    var replay = try trace.replayer.replayFromBytes(testing.allocator, bytes);
    defer replay.deinit();

    const report = try trace.diff.diff(testing.allocator, replay.spans, replay.spans);
    defer report.deinit(testing.allocator);
    try testing.expect(report.empty());
}

test "diff: extra span in actual is reported" {
    const expected = [_]trace.Span{
        .{ .id = "a", .trace_id = "d", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 5 },
    };
    const actual = [_]trace.Span{
        .{ .id = "a", .trace_id = "d", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 5 },
        .{ .id = "b", .parent_id = "a", .trace_id = "d", .kind = .turn, .name = "bonus-turn", .started_at_ns = 1, .finished_at_ns = 3 },
    };

    const expected_bytes = try writeTrace(testing.allocator, &expected);
    defer testing.allocator.free(expected_bytes);
    const actual_bytes = try writeTrace(testing.allocator, &actual);
    defer testing.allocator.free(actual_bytes);

    var exp_replay = try trace.replayer.replayFromBytes(testing.allocator, expected_bytes);
    defer exp_replay.deinit();
    var act_replay = try trace.replayer.replayFromBytes(testing.allocator, actual_bytes);
    defer act_replay.deinit();

    const report = try trace.diff.diff(testing.allocator, exp_replay.spans, act_replay.spans);
    defer report.deinit(testing.allocator);

    try testing.expect(!report.empty());
    try testing.expectEqual(@as(usize, 1), report.entries.len);
    try testing.expectEqual(trace.diff.Kind.extra, report.entries[0].kind);
    try testing.expectEqualStrings("bonus-turn", report.entries[0].span_name);
}

test "diff: status mismatch in a matched span is reported" {
    const expected = [_]trace.Span{
        .{ .id = "a", .trace_id = "d", .kind = .turn, .name = "turn-1", .started_at_ns = 0, .finished_at_ns = 1, .status = .ok },
    };
    const actual = [_]trace.Span{
        .{ .id = "a", .trace_id = "d", .kind = .turn, .name = "turn-1", .started_at_ns = 0, .finished_at_ns = 1, .status = .err },
    };

    const exp_bytes = try writeTrace(testing.allocator, &expected);
    defer testing.allocator.free(exp_bytes);
    const act_bytes = try writeTrace(testing.allocator, &actual);
    defer testing.allocator.free(act_bytes);

    var exp_replay = try trace.replayer.replayFromBytes(testing.allocator, exp_bytes);
    defer exp_replay.deinit();
    var act_replay = try trace.replayer.replayFromBytes(testing.allocator, act_bytes);
    defer act_replay.deinit();

    const report = try trace.diff.diff(testing.allocator, exp_replay.spans, act_replay.spans);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.entries.len);
    try testing.expectEqual(trace.diff.Kind.status, report.entries[0].kind);
}
