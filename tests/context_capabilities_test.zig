const std = @import("std");
const caps = @import("capabilities");

test "context_engine capability exists with correct tag" {
    try std.testing.expectEqual(@as(u8, 16), caps.Capability.context_engine.tag());
}

test "context_contributor capability exists with correct tag" {
    try std.testing.expectEqual(@as(u8, 17), caps.Capability.context_contributor.tag());
}

test "context capabilities have canonical names" {
    try std.testing.expectEqualStrings("context_engine", caps.Capability.context_engine.name());
    try std.testing.expectEqualStrings("context_contributor", caps.Capability.context_contributor.name());
}

test "context capabilities report v1 vtable" {
    try std.testing.expectEqual(@as(u16, 1), caps.currentVtableVersion(.context_engine));
    try std.testing.expectEqual(@as(u16, 1), caps.currentVtableVersion(.context_contributor));
}
