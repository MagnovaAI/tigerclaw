//! `ask_user` tool — surface a question to the operator.
//!
//! The tool cannot actually prompt from inside the react loop; it
//! returns a structured envelope the runtime's prompt responder
//! consumes outside the loop. For the unit test we assert the
//! envelope shape; full wiring into the permissions responder
//! lands when a UI frontend exists.
//!
//! Arguments: `{"question": "<prompt>"}`.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "ask_user",
    .description = "Pause and ask the human operator a question.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}
    ,
    .category = .control,
    .tags = &.{"control"},
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

    const payload = try std.fmt.allocPrint(inv.allocator, "ask:{s}", .{parsed.value.question});
    defer inv.allocator.free(payload);
    return schema.okResult(inv.allocator, inv.call.id, payload);
}

const Args = struct {
    question: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "ask_user: payload starts with ask: prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{
            .id = "c1",
            .name = "ask_user",
            .arguments_json = "{\"question\":\"which branch?\"}",
        },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);
    try testing.expect(std.mem.startsWith(u8, result.outcome.ok, "ask:"));
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "which branch?") != null);
}
