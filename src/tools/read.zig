//! `read` tool — load a file's contents from the workspace dir.
//!
//! Arguments: `{"path": "<relative path>"}`.
//! Output: file contents as UTF-8 bytes. Non-UTF-8 files should
//! pass through unchanged — the caller decides how to display.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "read",
    .description = "Read the full contents of a file in the session workspace.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
    ,
    .category = .read,
    .tags = &.{"fs"},
};

const max_bytes: usize = 4 * 1024 * 1024;

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    const path = extractPath(inv.call.arguments_json) orelse
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "missing 'path'");
    if (try schema.checkWorkspacePath(inv, path, .read)) |err_result| return err_result;

    const bytes = inv.workspace.readFileAlloc(
        inv.io,
        path,
        inv.allocator,
        .limited(max_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return schema.errResult(inv.allocator, inv.call.id, "fs.not_found", path),
        else => return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err)),
    };
    defer inv.allocator.free(bytes);
    return schema.okResult(inv.allocator, inv.call.id, bytes);
}

/// Pull the `path` field out of the raw JSON arguments without
/// pulling in `std.json` for a trivial shape. Tools that need
/// richer inputs switch to json.parseFromSlice.
fn extractPath(raw: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, raw, "\"path\"") orelse return null;
    var i = key_pos + "\"path\"".len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == ':' or raw[i] == '\t')) : (i += 1) {}
    if (i >= raw.len or raw[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < raw.len and raw[i] != '"') : (i += 1) {}
    if (i >= raw.len) return null;
    return raw[start..i];
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "read: returns file contents for a relative path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed a file in the workspace.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "hello from disk" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "read", .arguments_json = "{\"path\":\"hello.txt\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    try testing.expectEqualStrings("hello from disk", result.outcome.ok);
}

test "read: missing file is fs.not_found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c2", .name = "read", .arguments_json = "{\"path\":\"ghost\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("fs.not_found", result.outcome.err.id);
}

test "read: missing path argument is tool.args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c3", .name = "read", .arguments_json = "{}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("tool.args", result.outcome.err.id);
}
