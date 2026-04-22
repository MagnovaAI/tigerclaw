//! `random_seeded` — deterministic pseudo-random u64 from a seed.
//!
//! Arguments: `{"seed": <u64>, "count": <u32>}`. Output is a
//! space-separated list of `count` u64s drawn from a seeded
//! splitmix64 stream. Callers need to supply both fields so two
//! different tasks sharing a seed still diverge on `count`.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "random_seeded",
    .description = "Deterministic PRNG: N u64s from a caller-supplied seed.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"seed":{"type":"integer"},"count":{"type":"integer"}},"required":["seed","count"]}
    ,
    .category = .compute,
    .tags = &.{"util"},
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        Args,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();
    if (parsed.value.count == 0 or parsed.value.count > 1024) {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "count must be 1..1024");
    }

    var prng: std.Random.SplitMix64 = .init(parsed.value.seed);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(inv.allocator);
    var i: u32 = 0;
    while (i < parsed.value.count) : (i += 1) {
        if (i != 0) try out.append(inv.allocator, ' ');
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{prng.next()});
        try out.appendSlice(inv.allocator, s);
    }
    return schema.okResult(inv.allocator, inv.call.id, out.items);
}

const Args = struct {
    seed: u64,
    count: u32,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "random_seeded: identical inputs yield identical streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const call = types.ToolCall{
        .id = "c",
        .name = "random_seeded",
        .arguments_json = "{\"seed\":123,\"count\":5}",
    };
    const a = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(a.call_id);
    defer testing.allocator.free(a.outcome.ok);
    const b = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(b.call_id);
    defer testing.allocator.free(b.outcome.ok);
    try testing.expectEqualStrings(a.outcome.ok, b.outcome.ok);
}

test "random_seeded: different seed diverges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "random_seeded", .arguments_json = "{\"seed\":1,\"count\":3}" },
    });
    defer testing.allocator.free(a.call_id);
    defer testing.allocator.free(a.outcome.ok);
    const b = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "random_seeded", .arguments_json = "{\"seed\":2,\"count\":3}" },
    });
    defer testing.allocator.free(b.call_id);
    defer testing.allocator.free(b.outcome.ok);
    try testing.expect(!std.mem.eql(u8, a.outcome.ok, b.outcome.ok));
}
