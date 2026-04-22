//! Integration test: rubric + judge produce an overall pass
//! against a configured threshold.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const eval = tigerclaw.eval;

test "judge + rubric: exact match passes the rubric" {
    const r = eval.Rubric{
        .id = "r1",
        .criteria = &.{
            .{ .id = "length", .description = "", .weight = 1, .threshold = 0.8 },
            .{ .id = "overlap", .description = "", .weight = 1, .threshold = 0.8 },
        },
    };
    const j = try eval.judge.judge(testing.allocator, r, "hello world", "hello world");
    defer j.deinit(testing.allocator);
    try testing.expect(try r.passed(j.per_criterion, 0.9));
}

test "judge + rubric: total mismatch is refused under a reasonable threshold" {
    const r = eval.Rubric{
        .id = "r",
        .criteria = &.{.{ .id = "x", .description = "", .weight = 1, .threshold = 0.6 }},
    };
    const j = try eval.judge.judge(testing.allocator, r, "a", "quite a lot of expected text here");
    defer j.deinit(testing.allocator);
    try testing.expect(!try r.passed(j.per_criterion, 0.6));
}
