//! Golden outputs.
//!
//! A golden file maps `(scenario_id)` to an expected output
//! payload. The eval harness consults goldens to decide whether
//! a run's output matched expectations; when the assertion is
//! `exact_eq`, the output must match byte-for-byte.
//!
//! Format: JSONL, one `Entry` per line. Same rationale as
//! `dataset.zig` — shell-authorable.

const std = @import("std");

pub const Entry = struct {
    scenario_id: []const u8,
    expected: []const u8,
};

pub fn parseJsonl(allocator: std.mem.Allocator, bytes: []const u8) ![]Entry {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len != 0) count += 1;
    }

    const out = try allocator.alloc(Entry, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it2 = std.mem.splitScalar(u8, bytes, '\n');
    while (it2.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(Entry, allocator, line, .{});
        defer parsed.deinit();
        out[idx] = .{
            .scenario_id = try allocator.dupe(u8, parsed.value.scenario_id),
            .expected = try allocator.dupe(u8, parsed.value.expected),
        };
        idx += 1;
    }
    return out;
}

pub fn free(allocator: std.mem.Allocator, items: []Entry) void {
    for (items) |e| {
        allocator.free(e.scenario_id);
        allocator.free(e.expected);
    }
    allocator.free(items);
}

/// Lookup by scenario id. Returns `null` when the id has no
/// golden entry — the assertion layer decides what that means
/// (often: treat as a hard fail).
pub fn lookup(entries: []const Entry, id: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.scenario_id, id)) return e.expected;
    }
    return null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseJsonl: round-trip entries" {
    const src =
        \\{"scenario_id":"alpha","expected":"yes"}
        \\{"scenario_id":"beta","expected":"no"}
    ;
    const items = try parseJsonl(testing.allocator, src);
    defer free(testing.allocator, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("yes", items[0].expected);
}

test "lookup: finds by id, returns null otherwise" {
    const entries = [_]Entry{
        .{ .scenario_id = "a", .expected = "A" },
        .{ .scenario_id = "b", .expected = "B" },
    };
    try testing.expectEqualStrings("A", lookup(&entries, "a").?);
    try testing.expect(lookup(&entries, "missing") == null);
}
