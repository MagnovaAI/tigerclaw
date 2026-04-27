//! `apply_patch` tool — replace a file's contents wholesale.
//!
//! Minimal variant: the model supplies `{"path","contents"}` and
//! we overwrite atomically. A full unified-diff applier is a lot
//! more code and lives on the roadmap; this shim is enough for
//! the react loop to stage multi-file edits through one call
//! rather than N `write` calls.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");
const internal_writes = @import("../settings/internal_writes.zig");

pub const spec = schema.ToolSpec{
    .name = "apply_patch",
    .description = "Atomically overwrite a file with new contents.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"contents":{"type":"string"}},"required":["path","contents"]}
    ,
    .category = .write,
    .tags = &.{ "fs", "mutating" },
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        PatchArgs,
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
    return schema.okResult(inv.allocator, inv.call.id, "patched");
}

const PatchArgs = struct {
    path: []const u8,
    contents: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "apply_patch: overwrites atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "old" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "apply_patch", .arguments_json = "{\"path\":\"f.txt\",\"contents\":\"new\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    var buf: [16]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "f.txt", &buf);
    try testing.expectEqualStrings("new", bytes);
}
