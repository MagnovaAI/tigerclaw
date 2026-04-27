const std = @import("std");
const t = @import("ctx_types");
const recall = @import("ctx_recall");

const FakeIndex = struct {
    last_k: u8 = 0,
    last_query: []const u8 = "",

    fn queryImpl(self_ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, k: u8) error{Internal}![]t.RecallHit {
        const self: *FakeIndex = @ptrCast(@alignCast(self_ptr));
        self.last_k = k;
        self.last_query = query;
        const hits = allocator.alloc(t.RecallHit, 1) catch return error.Internal;
        hits[0] = .{ .entry_id = "e1", .score = 0.9, .snippet = "hello" };
        return hits;
    }
};

test "recall dispatches to memory index" {
    const allocator = std.testing.allocator;
    var fake: FakeIndex = .{};
    const idx = recall.MemoryIndex{
        .ptr = &fake,
        .query_fn = FakeIndex.queryImpl,
    };

    const hits = try recall.query(allocator, idx, "anything", 5);
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("e1", hits[0].entry_id);
    try std.testing.expectEqual(@as(u8, 5), fake.last_k);
    try std.testing.expectEqualStrings("anything", fake.last_query);
}

test "recall propagates index errors" {
    const FailIndex = struct {
        fn failQuery(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u8) error{Unavailable}![]t.RecallHit {
            return error.Unavailable;
        }
    };
    const allocator = std.testing.allocator;
    var fake: u8 = 0;
    const idx = recall.MemoryIndex{
        .ptr = &fake,
        .query_fn = FailIndex.failQuery,
    };
    try std.testing.expectError(error.Unavailable, recall.query(allocator, idx, "q", 1));
}
