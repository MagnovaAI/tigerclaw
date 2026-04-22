//! `gen_id` — deterministic ID derived from (seed, sequence).
//!
//! Arguments: `{"seed": "<string>", "index": <u64>}`.
//! Output: 16-byte hex (the lower half of SHA-256).
//!
//! The tool never calls a random source — that is `random_seeded`'s
//! job. `gen_id` is the "give me a stable name for this logical
//! thing" tool, intended for artefact IDs inside a run.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "gen_id",
    .description = "Derive a deterministic 128-bit hex id from (seed, index).",
    .arguments_schema_json =
    \\{"type":"object","properties":{"seed":{"type":"string"},"index":{"type":"integer"}},"required":["seed","index"]}
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

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(parsed.value.seed);
    var idx_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &idx_buf, parsed.value.index, .little);
    hasher.update(&idx_buf);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex: [32]u8 = undefined;
    const hex_bytes = std.fmt.bufPrint(&hex, "{x}", .{digest[0..16]}) catch unreachable;
    return schema.okResult(inv.allocator, inv.call.id, hex_bytes);
}

const Args = struct {
    seed: []const u8,
    index: u64,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "gen_id: same (seed, index) yields identical hex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const call = types.ToolCall{
        .id = "c1",
        .name = "gen_id",
        .arguments_json = "{\"seed\":\"demo\",\"index\":7}",
    };
    const a = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(a.call_id);
    defer testing.allocator.free(a.outcome.ok);
    const b = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(b.call_id);
    defer testing.allocator.free(b.outcome.ok);

    try testing.expectEqualStrings(a.outcome.ok, b.outcome.ok);
    try testing.expectEqual(@as(usize, 32), a.outcome.ok.len);
}

test "gen_id: different index changes the hex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "gen_id", .arguments_json = "{\"seed\":\"s\",\"index\":1}" },
    });
    defer testing.allocator.free(a.call_id);
    defer testing.allocator.free(a.outcome.ok);
    const b = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "gen_id", .arguments_json = "{\"seed\":\"s\",\"index\":2}" },
    });
    defer testing.allocator.free(b.call_id);
    defer testing.allocator.free(b.outcome.ok);
    try testing.expect(!std.mem.eql(u8, a.outcome.ok, b.outcome.ok));
}
