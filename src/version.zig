//! Single source of truth for the runtime version string.
//!
//! The string is independent of `build.zig.zon` so the runtime keeps a
//! byte-stable identifier it can print without a build-graph lookup. When
//! the next tag lands, update both this constant and `build.zig.zon` in the
//! same commit.

const std = @import("std");

pub const string = "0.1.0-alpha";

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "version.string is non-empty and semver-shaped" {
    try testing.expect(string.len > 0);
    // At least `<major>.<minor>.<patch>` shape.
    try testing.expect(std.mem.count(u8, string, ".") >= 2);
}
