//! `write` tool — create or overwrite a file in the workspace.
//!
//! Arguments: `{"path": "<relative path>", "contents": "<bytes>"}`.
//! Uses the shared `writeAtomic` helper so readers never see a
//! torn file.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");
const internal_writes = @import("../settings/internal_writes.zig");

pub const spec = schema.ToolSpec{
    .name = "write",
    .description = "Create or overwrite a file in the session workspace.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"contents":{"type":"string"}},"required":["path","contents"]}
    ,
    .category = .write,
    .tags = &.{ "fs", "mutating" },
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        WriteArgs,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

    if (try schema.checkWorkspacePath(inv, parsed.value.path, .write)) |err_result| return err_result;

    internal_writes.writeAtomic(inv.workspace, inv.io, parsed.value.path, parsed.value.contents) catch |err| {
        return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err));
    };
    return schema.okResult(inv.allocator, inv.call.id, "written");
}

const WriteArgs = struct {
    path: []const u8,
    contents: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "write: creates a file and round-trips contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{
            .id = "c1",
            .name = "write",
            .arguments_json = "{\"path\":\"out.txt\",\"contents\":\"hi\"}",
        },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    var buf: [32]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "out.txt", &buf);
    try testing.expectEqualStrings("hi", bytes);
}

test "write: invalid arguments surface tool.args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c2", .name = "write", .arguments_json = "not-json" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("tool.args", result.outcome.err.id);
}
