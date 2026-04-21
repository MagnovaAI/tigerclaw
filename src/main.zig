const std = @import("std");

pub fn main() !void {
    std.debug.print("tigerclaw v0.0.0 (zig 0.16)\n", .{});
}

test "smoke" {
    try std.testing.expect(1 + 1 == 2);
}
