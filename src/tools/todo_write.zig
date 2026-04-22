//! `todo_write` tool — capture a todo list for the current turn.
//!
//! The tool writes the list to a fixed path under the workspace
//! (`.tigerclaw-todos.json`) so the UI and subsequent turns can
//! read it without re-parsing the assistant transcript. Arguments
//! are pass-through — the handler does not interpret the todo
//! shape beyond asserting it is valid JSON.
//!
//! Arguments: `{"items": [...]}` (any JSON shape).

const std = @import("std");
const types = @import("../types/root.zig");
const schema = @import("schema.zig");
const internal_writes = @import("../settings/internal_writes.zig");

pub const spec = schema.ToolSpec{
    .name = "todo_write",
    .description = "Persist the agent's current todo list for this session.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"items":{"type":"array"}},"required":["items"]}
    ,
    .category = .control,
    .tags = &.{"control"},
};

const todos_path: []const u8 = ".tigerclaw-todos.json";

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    // Validate the arguments parse as JSON before writing; the
    // model might send a broken payload. We do not interpret the
    // shape — operators slot their own schema on top.
    var scanner: std.json.Scanner = .initCompleteInput(inv.allocator, inv.call.arguments_json);
    defer scanner.deinit();
    while (true) {
        const tok = scanner.next() catch {
            return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
        };
        if (tok == .end_of_document) break;
    }

    internal_writes.writeAtomic(inv.workspace, inv.io, todos_path, inv.call.arguments_json) catch |err| {
        return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err));
    };
    return schema.okResult(inv.allocator, inv.call.id, "todos written");
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "todo_write: valid payload is persisted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{
            .id = "c1",
            .name = "todo_write",
            .arguments_json = "{\"items\":[{\"title\":\"a\",\"done\":false}]}",
        },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    var buf: [256]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, todos_path, &buf);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"a\"") != null);
}

test "todo_write: invalid json is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c2", .name = "todo_write", .arguments_json = "{bogus" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("tool.args", result.outcome.err.id);
}
