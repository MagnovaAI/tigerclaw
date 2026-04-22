//! Integration tests for the transcript compactor.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const compaction = tigerclaw.agent.context.compaction;
const types = tigerclaw.types;

test "compaction: histories within head+tail are forwarded untouched" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "a" },
        .{ .role = .assistant, .content = "b" },
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 4 });
    defer compaction.deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 2), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqual(@as(usize, 0), r.hint.len);
}

test "compaction: middle is dropped when history is longer than head+tail" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "start" },
        .{ .role = .user, .content = "x1" },
        .{ .role = .user, .content = "x2" },
        .{ .role = .user, .content = "x3" },
        .{ .role = .user, .content = "tail1" },
        .{ .role = .user, .content = "tail2" },
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 2 });
    defer compaction.deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 3), r.messages.len);
    try testing.expectEqualStrings("start", r.messages[0].content);
    try testing.expectEqualStrings("tail1", r.messages[1].content);
    try testing.expectEqualStrings("tail2", r.messages[2].content);
    try testing.expectEqual(@as(usize, 3), r.dropped);
    try testing.expect(std.mem.indexOf(u8, r.hint, "dropped 3") != null);
}

test "compaction: head oversize is clamped to history length" {
    const msgs = [_]types.Message{.{ .role = .user, .content = "solo" }};
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 10, .keep_tail = 10 });
    defer compaction.deinitResult(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
}

test "compaction: output messages are independent copies of the inputs" {
    var user_buf = [_]u8{ 'h', 'e', 'y' };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = &user_buf },
        .{ .role = .assistant, .content = "fine" },
        .{ .role = .user, .content = "tail" },
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 1 });
    defer compaction.deinitResult(testing.allocator, r);
    user_buf[0] = 'X';
    try testing.expectEqualStrings("hey", r.messages[0].content);
}
