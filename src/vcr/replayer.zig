//! Reads a cassette back into memory.
//!
//! `replayFromBytes` returns every interaction behind an arena. Callers
//! can then ask `find` for the response that matches a live request —
//! finds are one-shot: each interaction can be consumed at most once per
//! playback, so repeated requests need repeated recordings.

const std = @import("std");
const cassette = @import("cassette.zig");
const matcher = @import("matcher.zig");

pub const ReplayError = error{
    EmptyCassette,
    UnsupportedFormat,
    InvalidJson,
} || std.mem.Allocator.Error;

pub const Cassette = struct {
    arena: std.heap.ArenaAllocator,
    header: cassette.Header,
    interactions: []cassette.Interaction,
    consumed: []bool,

    pub fn deinit(self: *Cassette) void {
        self.arena.deinit();
    }

    /// Returns the first matching un-consumed response. Matched entries
    /// are marked consumed and not re-served on the next call.
    pub fn find(
        self: *Cassette,
        policy: matcher.Policy,
        request: cassette.Request,
    ) ?cassette.Response {
        for (self.interactions, 0..) |i, idx| {
            if (self.consumed[idx]) continue;
            if (!matcher.matches(policy, request, i.request)) continue;
            self.consumed[idx] = true;
            return i.response;
        }
        return null;
    }
};

pub fn replayFromBytes(
    gpa: std.mem.Allocator,
    bytes: []const u8,
) ReplayError!Cassette {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    const header_line = nextNonEmpty(&lines) orelse return error.EmptyCassette;
    const header = std.json.parseFromSliceLeaky(
        cassette.Header,
        a,
        header_line,
        .{},
    ) catch return error.InvalidJson;
    cassette.checkFormat(header) catch return error.UnsupportedFormat;

    var list: std.array_list.Aligned(cassette.Interaction, null) = .empty;
    while (nextNonEmpty(&lines)) |line| {
        const i = std.json.parseFromSliceLeaky(
            cassette.Interaction,
            a,
            line,
            .{},
        ) catch return error.InvalidJson;
        try list.append(a, i);
    }

    const interactions = try list.toOwnedSlice(a);
    const consumed = try a.alloc(bool, interactions.len);
    @memset(consumed, false);

    return .{
        .arena = arena,
        .header = header,
        .interactions = interactions,
        .consumed = consumed,
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

test "replayFromBytes: empty input returns EmptyCassette" {
    try testing.expectError(error.EmptyCassette, replayFromBytes(testing.allocator, ""));
}

test "replayFromBytes: foreign format_version rejected" {
    const bytes =
        \\{"format_version":99,"cassette_id":"c","created_at_ns":0}
    ;
    try testing.expectError(error.UnsupportedFormat, replayFromBytes(testing.allocator, bytes));
}

test "find: consumed entry is not re-served" {
    const bytes =
        \\{"format_version":1,"cassette_id":"c","created_at_ns":0}
        \\{"request":{"method":"GET","url":"/x"},"response":{"status":200,"body":"first"}}
        \\{"request":{"method":"GET","url":"/x"},"response":{"status":200,"body":"second"}}
    ;
    var cs = try replayFromBytes(testing.allocator, bytes);
    defer cs.deinit();

    const a = cs.find(.{}, .{ .method = "GET", .url = "/x" });
    const b = cs.find(.{}, .{ .method = "GET", .url = "/x" });
    const c = cs.find(.{}, .{ .method = "GET", .url = "/x" });

    try testing.expectEqualStrings("first", a.?.body);
    try testing.expectEqualStrings("second", b.?.body);
    try testing.expect(c == null);
}
