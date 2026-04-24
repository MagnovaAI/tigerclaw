//! Integration tests for the context window estimator and the
//! overall engine flow.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const context = tigerclaw.agent.context;
const types = tigerclaw.types;

test "context window: classify thresholds match documented cut-offs" {
    const w = context.Window{ .capacity_tokens = 1_000, .reserve_output_tokens = 0 };
    try testing.expectEqual(context.WindowStatus.ok, w.classify(500));
    try testing.expectEqual(context.WindowStatus.warm, w.classify(800));
    try testing.expectEqual(context.WindowStatus.pressure, w.classify(950));
    try testing.expectEqual(context.WindowStatus.overflow, w.classify(1_100));
}

test "context window: estimate scales with message content length" {
    const w = context.Window{ .capacity_tokens = 10_000 };
    const short = [_]types.Message{types.Message.literal(.user, "hi")};
    const long = [_]types.Message{types.Message.literal(.user, "x" ** 1024)};
    try testing.expect(w.estimateMessages(&long) > w.estimateMessages(&short));
}

test "context engine: warm history is forwarded without compaction" {
    var e = context.Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 1_000, .reserve_output_tokens = 0 },
    });

    const msgs = [_]types.Message{
        types.Message.literal(.user, "a" ** 200),
        types.Message.literal(.assistant, "b" ** 200),
    };
    var prep = try e.prepareForSend(&msgs);
    defer prep.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), prep.messages.len);
    try testing.expectEqual(@as(u32, 0), prep.feedback.hints_added);
}

test "context engine: overflow compacts and leaves a hint" {
    var e = context.Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 20, .reserve_output_tokens = 0 },
        .policy = .{ .keep_head = 1, .keep_tail = 1 },
    });

    const msgs = [_]types.Message{
        types.Message.literal(.user, "a" ** 64),
        types.Message.literal(.assistant, "b" ** 64),
        types.Message.literal(.user, "c" ** 64),
        types.Message.literal(.assistant, "d" ** 64),
    };
    var prep = try e.prepareForSend(&msgs);
    defer prep.deinit(testing.allocator);

    try testing.expect(prep.messages.len < msgs.len);
    try testing.expect(prep.hint.len > 0);
    try testing.expect(prep.feedback.before_messages == 4);
}

test "context references: dedupe and iteration" {
    var r = context.References.init(testing.allocator);
    defer r.deinit();

    _ = try r.add(.file, "/a");
    _ = try r.add(.file, "/a");
    _ = try r.add(.url, "/a");
    try testing.expectEqual(@as(usize, 2), r.len());
}

test "context hints: render produces a compacted block" {
    var h = context.Hints.init(testing.allocator);
    defer h.deinit();
    try h.push("keep: goal");
    try h.push("files: /x");

    const out = try h.render(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "[compacted]\n"));
}

test "context feedback: effectiveness heuristic matches the documented rule" {
    const good = context.FeedbackRecord{
        .before_messages = 10,
        .after_messages = 4,
        .before_tokens = 1_000,
        .after_tokens = 100,
        .hints_added = 1,
    };
    try testing.expect(good.wasEffective());
    const bad = context.FeedbackRecord{
        .before_messages = 10,
        .after_messages = 6,
        .before_tokens = 1_000,
        .after_tokens = 980,
        .hints_added = 1,
    };
    try testing.expect(!bad.wasEffective());
}
