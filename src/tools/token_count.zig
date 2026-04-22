//! `token_count` — estimate a text's token length using the same
//! deterministic heuristic the budget and ledger use. Useful for
//! the agent to gate its own message size before sending.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");
const token_estimator = @import("../llm/token_estimator.zig");

pub const spec = schema.ToolSpec{
    .name = "token_count",
    .description = "Estimate the deterministic token count of a text.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
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

    const n = token_estimator.estimate(parsed.value.text);
    const payload = try std.fmt.allocPrint(inv.allocator, "{d}", .{n});
    defer inv.allocator.free(payload);
    return schema.okResult(inv.allocator, inv.call.id, payload);
}

const Args = struct {
    text: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "token_count: matches the estimator for the same text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "abcdefghijklmnop";
    const expected = token_estimator.estimate(text);

    const call = types.ToolCall{
        .id = "c",
        .name = "token_count",
        .arguments_json = "{\"text\":\"abcdefghijklmnop\"}",
    };
    const r = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.ok);
    var buf: [8]u8 = undefined;
    const expected_str = try std.fmt.bufPrint(&buf, "{d}", .{expected});
    try testing.expectEqualStrings(expected_str, r.outcome.ok);
}
