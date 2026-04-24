const std = @import("std");
const engine = @import("ctx_engine");
const reg = @import("ctx_registry");

test "registry stores and enumerates contributors in insertion order" {
    const allocator = std.testing.allocator;
    var r = reg.Registry.init(allocator);
    defer r.deinit();

    var dummy_a: u8 = 0;
    var dummy_b: u8 = 0;
    const vt = engine.ContextContributorVTable{
        .contribute = undefined,
        .dispose = undefined,
    };

    try r.add(.{ .id = "a", .band = 10, .ptr = &dummy_a, .vtable = &vt });
    try r.add(.{ .id = "b", .band = 20, .ptr = &dummy_b, .vtable = &vt });

    const list = r.all();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0].id);
    try std.testing.expectEqualStrings("b", list[1].id);
}

test "registry rejects duplicate ids" {
    const allocator = std.testing.allocator;
    var r = reg.Registry.init(allocator);
    defer r.deinit();

    var dummy: u8 = 0;
    const vt = engine.ContextContributorVTable{
        .contribute = undefined,
        .dispose = undefined,
    };

    try r.add(.{ .id = "a", .band = 0, .ptr = &dummy, .vtable = &vt });
    try std.testing.expectError(error.DuplicateContributor, r.add(.{ .id = "a", .band = 0, .ptr = &dummy, .vtable = &vt }));
}
