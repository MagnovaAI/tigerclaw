//! Aggregates tool-call spans into a small histogram.
//!
//! Counts invocations by `Span.name` for spans of kind `.tool_call`. The
//! result is a sorted slice (descending by count, then ascending by
//! name) — deterministic for every identical input stream, which the
//! trace diff layer relies on.

const std = @import("std");
const span_mod = @import("span.zig");

pub const Entry = struct {
    name: []const u8,
    count: u32,
    ok: u32,
    err: u32,
    cancelled: u32,
};

pub const Summary = struct {
    entries: []Entry,

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        for (self.entries) |e| allocator.free(e.name);
        allocator.free(self.entries);
    }

    pub fn totalCalls(self: Summary) u32 {
        var sum: u32 = 0;
        for (self.entries) |e| sum += e.count;
        return sum;
    }
};

pub fn summarize(
    allocator: std.mem.Allocator,
    spans: []const span_mod.Span,
) !Summary {
    var map: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    defer map.deinit(allocator);

    for (spans) |s| {
        if (s.kind != .tool_call) continue;

        const gop = try map.getOrPut(allocator, s.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .name = s.name,
                .count = 0,
                .ok = 0,
                .err = 0,
                .cancelled = 0,
            };
        }
        gop.value_ptr.count += 1;
        switch (s.status) {
            .ok => gop.value_ptr.ok += 1,
            .err => gop.value_ptr.err += 1,
            .cancelled => gop.value_ptr.cancelled += 1,
        }
    }

    const entries = try allocator.alloc(Entry, map.count());
    errdefer {
        for (entries[0..map.count()]) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |kv| : (i += 1) {
        entries[i] = .{
            .name = try allocator.dupe(u8, kv.value_ptr.name),
            .count = kv.value_ptr.count,
            .ok = kv.value_ptr.ok,
            .err = kv.value_ptr.err,
            .cancelled = kv.value_ptr.cancelled,
        };
    }

    std.sort.pdq(Entry, entries, {}, lessThan);
    return .{ .entries = entries };
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.count != b.count) return a.count > b.count; // descending
    return std.mem.lessThan(u8, a.name, b.name);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn mkTool(name: []const u8, status: span_mod.Status) span_mod.Span {
    return .{
        .id = name,
        .trace_id = "t",
        .kind = .tool_call,
        .name = name,
        .started_at_ns = 0,
        .finished_at_ns = 1,
        .status = status,
    };
}

test "summarize: counts per-name and totals" {
    const spans = [_]span_mod.Span{
        mkTool("read", .ok),
        mkTool("read", .ok),
        mkTool("read", .err),
        mkTool("write", .ok),
    };
    const s = try summarize(testing.allocator, &spans);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), s.entries.len);
    try testing.expectEqualStrings("read", s.entries[0].name);
    try testing.expectEqual(@as(u32, 3), s.entries[0].count);
    try testing.expectEqual(@as(u32, 2), s.entries[0].ok);
    try testing.expectEqual(@as(u32, 1), s.entries[0].err);

    try testing.expectEqualStrings("write", s.entries[1].name);
    try testing.expectEqual(@as(u32, 1), s.entries[1].count);

    try testing.expectEqual(@as(u32, 4), s.totalCalls());
}

test "summarize: non-tool spans are ignored" {
    const spans = [_]span_mod.Span{
        .{ .id = "a", .trace_id = "t", .kind = .root, .name = "root", .started_at_ns = 0, .finished_at_ns = 1 },
        .{ .id = "b", .trace_id = "t", .kind = .turn, .name = "turn-1", .started_at_ns = 0, .finished_at_ns = 1 },
        mkTool("read", .ok),
    };
    const s = try summarize(testing.allocator, &spans);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), s.entries.len);
    try testing.expectEqualStrings("read", s.entries[0].name);
}

test "summarize: tie on count sorts by name ascending" {
    const spans = [_]span_mod.Span{
        mkTool("zebra", .ok),
        mkTool("apple", .ok),
        mkTool("mango", .ok),
    };
    const s = try summarize(testing.allocator, &spans);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), s.entries.len);
    try testing.expectEqualStrings("apple", s.entries[0].name);
    try testing.expectEqualStrings("mango", s.entries[1].name);
    try testing.expectEqualStrings("zebra", s.entries[2].name);
}

test "summarize: empty input yields zero entries" {
    const spans: []const span_mod.Span = &.{};
    const s = try summarize(testing.allocator, spans);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.entries.len);
    try testing.expectEqual(@as(u32, 0), s.totalCalls());
}
