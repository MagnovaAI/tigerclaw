//! Streaming trace replayer.
//!
//! Parses the envelope + span JSON-lines written by `recorder.zig`. The
//! replayer owns its own arena so span slices and attribute JSON blobs
//! stay alive for the lifetime of the replay. Callers iterate spans via
//! `nextSpan()` until it returns null.

const std = @import("std");
const schema = @import("schema.zig");
const span_mod = @import("span.zig");

pub const ReplayError = error{
    EmptyTrace,
    UnsupportedSchema,
    InvalidJson,
} || std.mem.Allocator.Error;

/// A complete in-memory replay — parses the envelope, materialises every
/// span, and hands both back in one shot. The arena inside `Replay`
/// owns all allocations; call `deinit` to free them.
pub const Replay = struct {
    arena: std.heap.ArenaAllocator,
    envelope: schema.Envelope,
    spans: []span_mod.Span,

    pub fn deinit(self: *Replay) void {
        self.arena.deinit();
    }
};

pub fn replayFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ReplayError!Replay {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    const envelope_line = nextNonEmpty(&lines) orelse return error.EmptyTrace;
    const envelope = std.json.parseFromSliceLeaky(
        schema.Envelope,
        arena_allocator,
        envelope_line,
        .{},
    ) catch return error.InvalidJson;
    schema.checkVersion(envelope) catch return error.UnsupportedSchema;

    var span_list: std.array_list.Aligned(span_mod.Span, null) = .empty;
    while (nextNonEmpty(&lines)) |line| {
        const s = std.json.parseFromSliceLeaky(
            span_mod.Span,
            arena_allocator,
            line,
            .{},
        ) catch return error.InvalidJson;
        try span_list.append(arena_allocator, s);
    }

    return .{
        .arena = arena,
        .envelope = envelope,
        .spans = try span_list.toOwnedSlice(arena_allocator),
    };
}

fn nextNonEmpty(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |line| {
        if (line.len > 0) return line;
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "replayFromBytes: empty input returns EmptyTrace" {
    try testing.expectError(error.EmptyTrace, replayFromBytes(testing.allocator, ""));
}

test "replayFromBytes: envelope-only input yields zero spans" {
    const bytes =
        \\{"schema_version":2,"trace_id":"t","run_id":"r","started_at_ns":0,"mode":"run"}
    ;
    var replay = try replayFromBytes(testing.allocator, bytes);
    defer replay.deinit();

    try testing.expectEqualStrings("t", replay.envelope.trace_id);
    try testing.expectEqual(@as(usize, 0), replay.spans.len);
}

test "replayFromBytes: foreign schema_version is rejected" {
    const bytes =
        \\{"schema_version":99,"trace_id":"t","run_id":"r","started_at_ns":0,"mode":"run"}
    ;
    try testing.expectError(error.UnsupportedSchema, replayFromBytes(testing.allocator, bytes));
}

test "replayFromBytes: malformed envelope surfaces InvalidJson" {
    const bytes = "{not even json";
    try testing.expectError(error.InvalidJson, replayFromBytes(testing.allocator, bytes));
}
