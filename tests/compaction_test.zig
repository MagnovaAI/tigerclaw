//! Integration tests for the transcript compactor.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const compaction = tigerclaw.agent.context.compaction;
const types = tigerclaw.types;

test "compaction: histories within head+tail are forwarded untouched" {
    const msgs = [_]types.Message{
        types.Message.literal(.user, "a"),
        types.Message.literal(.assistant, "b"),
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 4 });
    defer compaction.deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 2), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqual(@as(usize, 0), r.hint.len);
}

test "compaction: middle is dropped when history is longer than head+tail" {
    const msgs = [_]types.Message{
        types.Message.literal(.user, "start"),
        types.Message.literal(.user, "x1"),
        types.Message.literal(.user, "x2"),
        types.Message.literal(.user, "x3"),
        types.Message.literal(.user, "tail1"),
        types.Message.literal(.user, "tail2"),
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 2 });
    defer compaction.deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 3), r.messages.len);
    try testing.expectEqualStrings("start", r.messages[0].flatText());
    try testing.expectEqualStrings("tail1", r.messages[1].flatText());
    try testing.expectEqualStrings("tail2", r.messages[2].flatText());
    try testing.expectEqual(@as(usize, 3), r.dropped);
    try testing.expect(std.mem.indexOf(u8, r.hint, "dropped 3") != null);
}

test "compaction: head oversize is clamped to history length" {
    const msgs = [_]types.Message{types.Message.literal(.user, "solo")};
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 10, .keep_tail = 10 });
    defer compaction.deinitResult(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
}

test "compaction: output messages are independent copies of the inputs" {
    // Build the head message with an owned, mutable backing buffer
    // so we can prove `compact` duplicates rather than aliases.
    const head = try types.Message.allocText(testing.allocator, .user, "hey");
    defer head.freeOwned(testing.allocator);
    const msgs = [_]types.Message{
        head,
        types.Message.literal(.assistant, "fine"),
        types.Message.literal(.user, "tail"),
    };
    const r = try compaction.compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 1 });
    defer compaction.deinitResult(testing.allocator, r);

    // Mutate the original head's first text byte. If `compact`
    // aliased the slice the assertion below would fail.
    const head_text_block = &@constCast(head.content)[0];
    switch (head_text_block.*) {
        .text => |t| @constCast(t)[0] = 'X',
        else => unreachable,
    }
    try testing.expectEqualStrings("hey", r.messages[0].flatText());
}
