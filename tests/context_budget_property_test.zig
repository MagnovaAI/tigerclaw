const std = @import("std");
const t = @import("ctx_types");
const assemble = @import("ctx_assemble");

fn randomSections(
    allocator: std.mem.Allocator,
    rng: std.Random,
    count: usize,
) ![]t.Section {
    const arr = try allocator.alloc(t.Section, count);
    errdefer allocator.free(arr);

    // Track how many origins have been allocated so a mid-loop failure
    // frees only the ones that actually got allocated.
    var built: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < built) : (j += 1) allocator.free(arr[j].origin);
    }

    for (arr, 0..) |*s, i| {
        const origin = try std.fmt.allocPrint(allocator, "o{d}", .{i});
        s.* = .{
            .kind = .history_turn,
            .role = .user,
            .content = "x",
            .priority = rng.intRangeAtMost(u8, 0, 255),
            .token_estimate = rng.intRangeAtMost(u32, 1, 100),
            .tags = &.{},
            .pinned = false,
            .origin = origin,
        };
        built += 1;
    }
    return arr;
}

fn freeSections(allocator: std.mem.Allocator, arr: []t.Section) void {
    for (arr) |s| allocator.free(s.origin);
    allocator.free(arr);
}

test "property: budget never exceeded over random inputs" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const count = rng.intRangeAtMost(usize, 0, 50);
        const budget = rng.intRangeAtMost(u32, 0, 5000);
        const input = try randomSections(allocator, rng, count);
        defer freeSections(allocator, input);

        const res = try assemble.fit(allocator, input, budget);
        defer allocator.free(res.sections);
        defer allocator.free(res.dropped);
        try std.testing.expect(res.estimated_tokens <= budget);
    }
}

test "property: kept + dropped count equals input count" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const count = rng.intRangeAtMost(usize, 0, 30);
        const input = try randomSections(allocator, rng, count);
        defer freeSections(allocator, input);

        const res = try assemble.fit(allocator, input, 500);
        defer allocator.free(res.sections);
        defer allocator.free(res.dropped);
        try std.testing.expectEqual(count, res.sections.len + res.dropped.len);
    }
}

test "property: kept sections are in non-decreasing priority" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const input = try randomSections(allocator, rng, 20);
        defer freeSections(allocator, input);

        const res = try assemble.fit(allocator, input, 1000);
        defer allocator.free(res.sections);
        defer allocator.free(res.dropped);

        var prev: u8 = 0;
        for (res.sections) |s| {
            try std.testing.expect(s.priority >= prev);
            prev = s.priority;
        }
    }
}
