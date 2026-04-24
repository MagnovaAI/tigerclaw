const std = @import("std");
const t = @import("ctx_types");
const assemble = @import("ctx_assemble");

fn mkSection(kind: t.SectionKind, priority: u8, tokens: u32, origin: []const u8) t.Section {
    return .{
        .kind = kind,
        .role = .user,
        .content = "c",
        .priority = priority,
        .token_estimate = tokens,
        .tags = &.{},
        .pinned = false,
        .origin = origin,
    };
}

test "sortSections: ascending by priority then origin" {
    const input = [_]t.Section{
        mkSection(.history_turn, 5, 10, "b"),
        mkSection(.history_turn, 1, 10, "a"),
        mkSection(.history_turn, 5, 10, "a"),
    };
    var buf: [3]t.Section = undefined;
    const sorted = assemble.sortSections(&buf, &input);
    try std.testing.expectEqual(@as(u8, 1), sorted[0].priority);
    try std.testing.expectEqual(@as(u8, 5), sorted[1].priority);
    try std.testing.expectEqualStrings("a", sorted[1].origin);
    try std.testing.expectEqualStrings("b", sorted[2].origin);
}

test "fit: greedy fill under budget drops over-budget lowest priority" {
    const allocator = std.testing.allocator;
    const input = [_]t.Section{
        mkSection(.system_preamble, 0, 20, "soul"),
        mkSection(.current_prompt, 1, 10, "prompt"),
        mkSection(.history_turn, 10, 50, "h1"),
        mkSection(.history_turn, 11, 30, "h2"),
    };
    const res = try assemble.fit(allocator, &input, 60);
    defer allocator.free(res.sections);
    defer allocator.free(res.dropped);

    // soul(20) + prompt(10) = 30 kept. h1(50) over → dropped. h2(30): 30+30=60 ≤ 60 → kept.
    try std.testing.expectEqual(@as(usize, 3), res.sections.len);
    try std.testing.expectEqual(@as(u32, 60), res.estimated_tokens);
    try std.testing.expectEqual(@as(usize, 1), res.dropped.len);
    try std.testing.expectEqual(t.DropReason.over_budget, res.dropped[0].reason);
    try std.testing.expectEqualStrings("h1", res.dropped[0].section.origin);
}

test "fit: empty input returns empty result" {
    const allocator = std.testing.allocator;
    const res = try assemble.fit(allocator, &.{}, 100);
    defer allocator.free(res.sections);
    defer allocator.free(res.dropped);
    try std.testing.expectEqual(@as(usize, 0), res.sections.len);
    try std.testing.expectEqual(@as(u32, 0), res.estimated_tokens);
    try std.testing.expectEqual(@as(usize, 0), res.dropped.len);
}

test "fit: budget=0 drops everything" {
    const allocator = std.testing.allocator;
    const input = [_]t.Section{mkSection(.current_prompt, 0, 5, "p")};
    const res = try assemble.fit(allocator, &input, 0);
    defer allocator.free(res.sections);
    defer allocator.free(res.dropped);
    try std.testing.expectEqual(@as(usize, 0), res.sections.len);
    try std.testing.expectEqual(@as(usize, 1), res.dropped.len);
}
