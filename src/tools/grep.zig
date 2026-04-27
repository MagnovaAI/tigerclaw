//! `grep` tool — literal (non-regex) substring search across files
//! in the workspace directory.
//!
//! Arguments: `{"path": "<rel file>", "pattern": "<literal>"}`.
//! Returns matching lines prefixed by `<line_no>:`. Scope is one
//! file; cross-file search lands once a walker exists.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "grep",
    .description = "Search for a literal substring inside a single file.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"}},"required":["path","pattern"]}
    ,
    .category = .read,
    .tags = &.{"fs"},
};

const max_bytes: usize = 4 * 1024 * 1024;

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        GrepArgs,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

    if (try schema.checkWorkspacePath(inv, parsed.value.path, .read)) |err_result| return err_result;

    const src = inv.workspace.readFileAlloc(
        inv.io,
        parsed.value.path,
        inv.allocator,
        .limited(max_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return schema.errResult(inv.allocator, inv.call.id, "fs.not_found", parsed.value.path),
        else => return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err)),
    };
    defer inv.allocator.free(src);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(inv.allocator);

    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, parsed.value.pattern) != null) {
            var buf: [12]u8 = undefined;
            const pre = try std.fmt.bufPrint(&buf, "{d}:", .{line_no});
            try out.appendSlice(inv.allocator, pre);
            try out.appendSlice(inv.allocator, line);
            try out.append(inv.allocator, '\n');
        }
    }

    return schema.okResult(inv.allocator, inv.call.id, out.items);
}

const GrepArgs = struct {
    path: []const u8,
    pattern: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "grep: finds matches with line numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.txt",
        .data = "first line\nsecond line with needle\nthird line\nneedle again\n",
    });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "grep", .arguments_json = "{\"path\":\"log.txt\",\"pattern\":\"needle\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "2:second line with needle") != null);
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "4:needle again") != null);
}

test "grep: no matches returns empty payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "nothing interesting" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c2", .name = "grep", .arguments_json = "{\"path\":\"f.txt\",\"pattern\":\"ghost\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);
    try testing.expectEqual(@as(usize, 0), result.outcome.ok.len);
}
