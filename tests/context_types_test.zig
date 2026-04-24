const std = @import("std");
const ctx_types = @import("ctx_types");

test "SectionKind covers all specified kinds" {
    try std.testing.expectEqual(@as(usize, 7), @typeInfo(ctx_types.SectionKind).@"enum".fields.len);
}

test "Section default fields sane" {
    const s = ctx_types.Section{
        .kind = .current_prompt,
        .role = .user,
        .content = "hi",
        .priority = 0,
        .token_estimate = 1,
        .tags = &.{},
        .pinned = false,
        .origin = "test",
    };
    try std.testing.expectEqual(ctx_types.SectionKind.current_prompt, s.kind);
    try std.testing.expectEqual(@as(u32, 1), s.token_estimate);
}

test "Role has 4 variants" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(ctx_types.Role).@"enum".fields.len);
}
