//! Integration tests for `bless`: render + persist + reload.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const eval = tigerclaw.eval;

test "bless.renderJsonl: deterministic order and shape" {
    const obs = [_]eval.Observation{
        .{ .scenario_id = "zeta", .output = "zz" },
        .{ .scenario_id = "alpha", .output = "aa" },
        .{ .scenario_id = "mu", .output = "mm" },
    };
    const bytes = try eval.bless.renderJsonl(testing.allocator, &obs);
    defer testing.allocator.free(bytes);

    const a = std.mem.indexOf(u8, bytes, "\"scenario_id\":\"alpha\"").?;
    const m = std.mem.indexOf(u8, bytes, "\"scenario_id\":\"mu\"").?;
    const z = std.mem.indexOf(u8, bytes, "\"scenario_id\":\"zeta\"").?;
    try testing.expect(a < m);
    try testing.expect(m < z);
}

test "bless.writeGolden: persisted file parses back as a golden" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const obs = [_]eval.Observation{
        .{ .scenario_id = "a", .output = "AA" },
        .{ .scenario_id = "b", .output = "BB" },
    };
    try eval.bless.writeGolden(testing.allocator, tmp.dir, testing.io, "g.jsonl", &obs);

    var buf: [4 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "g.jsonl", &buf);
    const entries = try eval.golden.parseJsonl(testing.allocator, bytes);
    defer eval.golden.free(testing.allocator, entries);

    try testing.expectEqualStrings("AA", eval.golden.lookup(entries, "a").?);
    try testing.expectEqualStrings("BB", eval.golden.lookup(entries, "b").?);
}
