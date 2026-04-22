//! `task_delegate` tool — hand a sub-task to another agent.
//!
//! Without the multi-agent scheduler (deferred), this tool is a
//! manifest of intent: it records the delegation request as a
//! structured payload the runtime can pick up later. The agent
//! proceeds with its next turn assuming the delegation will
//! complete elsewhere.
//!
//! Arguments: `{"target": "<agent id>", "task": "<description>"}`.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "task_delegate",
    .description = "Record a delegation of a sub-task to another agent.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"target":{"type":"string"},"task":{"type":"string"}},"required":["target","task"]}
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

    const payload = try std.fmt.allocPrint(
        inv.allocator,
        "delegated to {s}: {s}",
        .{ parsed.value.target, parsed.value.task },
    );
    defer inv.allocator.free(payload);
    return schema.okResult(inv.allocator, inv.call.id, payload);
}

const Args = struct {
    target: []const u8,
    task: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "task_delegate: records target and task in payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{
            .id = "c1",
            .name = "task_delegate",
            .arguments_json = "{\"target\":\"agent-2\",\"task\":\"review PR\"}",
        },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "agent-2") != null);
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "review PR") != null);
}
