//! Free-form key/value pairs attached to turns, tool calls, etc.
//!
//! Intentionally tiny. Anything bigger than a handful of pairs should have
//! its own typed struct.

const std = @import("std");

pub const Metadata = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn get(self: Metadata, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Metadata.get returns the matching value or null" {
    const m = Metadata{
        .entries = &.{
            .{ .key = "session_id", .value = "sess-1" },
            .{ .key = "agent", .value = "planner" },
        },
    };
    try testing.expectEqualStrings("sess-1", m.get("session_id").?);
    try testing.expectEqualStrings("planner", m.get("agent").?);
    try testing.expect(m.get("missing") == null);
}

test "Metadata: empty by default" {
    const m = Metadata{};
    try testing.expectEqual(@as(usize, 0), m.entries.len);
    try testing.expect(m.get("anything") == null);
}

test "Metadata: JSON roundtrip preserves entry order" {
    const m = Metadata{
        .entries = &.{
            .{ .key = "a", .value = "1" },
            .{ .key = "b", .value = "2" },
        },
    };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, m, .{});
    defer testing.allocator.free(s);

    const parsed = try std.json.parseFromSlice(Metadata, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try testing.expectEqualStrings("a", parsed.value.entries[0].key);
    try testing.expectEqualStrings("2", parsed.value.entries[1].value);
}
