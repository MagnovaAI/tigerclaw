//! Bless — write the current observed outputs out as the new
//! golden. The `bless` command is an operator escape hatch: when
//! the tool's output legitimately changed (say, because the
//! scenario itself changed), you run `bless` to accept the new
//! output as canonical.
//!
//! Because this rewrites the contract under the bench and eval
//! subsystems, it is intentionally a separate code path from the
//! normal "read golden" flow. An operator has to opt in.

const std = @import("std");
const golden = @import("golden.zig");
const internal_writes = @import("../settings/internal_writes.zig");

pub const Observation = struct {
    scenario_id: []const u8,
    output: []const u8,
};

fn lessThan(_: void, a: Observation, b: Observation) bool {
    return std.mem.order(u8, a.scenario_id, b.scenario_id) == .lt;
}

/// Render observations as a JSONL golden file. Sorted by
/// scenario_id so the on-disk file is deterministic.
pub fn renderJsonl(
    allocator: std.mem.Allocator,
    observations: []const Observation,
) ![]u8 {
    const sorted = try allocator.dupe(Observation, observations);
    defer allocator.free(sorted);
    std.mem.sort(Observation, sorted, {}, lessThan);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (sorted) |o| {
        const entry = golden.Entry{ .scenario_id = o.scenario_id, .expected = o.output };
        const line = try std.json.Stringify.valueAlloc(allocator, entry, .{});
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// Persist observations as a new golden file in `dir` at `sub_path`.
/// Uses the shared atomic-write helper so a crash leaves either the
/// old file or the new file, never a torn one.
pub fn writeGolden(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    observations: []const Observation,
) !void {
    const bytes = try renderJsonl(allocator, observations);
    defer allocator.free(bytes);
    try internal_writes.writeAtomic(dir, io, sub_path, bytes);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "renderJsonl: sorted, JSONL, one entry per line" {
    const obs = [_]Observation{
        .{ .scenario_id = "z", .output = "Z" },
        .{ .scenario_id = "a", .output = "A" },
    };
    const bytes = try renderJsonl(testing.allocator, &obs);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"a\"") != null);
    const first_a = std.mem.indexOf(u8, bytes, "\"scenario_id\":\"a\"").?;
    const first_z = std.mem.indexOf(u8, bytes, "\"scenario_id\":\"z\"").?;
    try testing.expect(first_a < first_z);
}

test "writeGolden: bless output round-trips through golden.parseJsonl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const obs = [_]Observation{
        .{ .scenario_id = "one", .output = "first" },
        .{ .scenario_id = "two", .output = "second" },
    };
    try writeGolden(testing.allocator, tmp.dir, testing.io, "golden.jsonl", &obs);

    var buf: [4 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "golden.jsonl", &buf);
    const entries = try golden.parseJsonl(testing.allocator, bytes);
    defer golden.free(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("first", golden.lookup(entries, "one").?);
}
