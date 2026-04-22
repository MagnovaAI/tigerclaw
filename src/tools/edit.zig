//! `edit` tool — in-place substring replacement.
//!
//! Arguments: `{"path": "<rel>", "find": "<str>", "replace": "<str>"}`.
//! `find` must appear exactly once in the file to avoid accidental
//! mass edits; the tool refuses otherwise.

const std = @import("std");
const types = @import("../types/root.zig");
const schema = @import("schema.zig");
const internal_writes = @import("../settings/internal_writes.zig");

pub const spec = schema.ToolSpec{
    .name = "edit",
    .description = "Replace a single unique substring in a file.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"find":{"type":"string"},"replace":{"type":"string"}},"required":["path","find","replace"]}
    ,
    .category = .write,
    .tags = &.{ "fs", "mutating" },
};

const max_bytes: usize = 4 * 1024 * 1024;

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        EditArgs,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

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

    const first = std.mem.indexOf(u8, src, parsed.value.find) orelse
        return schema.errResult(inv.allocator, inv.call.id, "edit.no_match", "find string not present");
    const second = std.mem.indexOfPos(u8, src, first + parsed.value.find.len, parsed.value.find);
    if (second != null) return schema.errResult(inv.allocator, inv.call.id, "edit.ambiguous", "find string appears more than once");

    const new_len = src.len - parsed.value.find.len + parsed.value.replace.len;
    const new_buf = try inv.allocator.alloc(u8, new_len);
    defer inv.allocator.free(new_buf);
    @memcpy(new_buf[0..first], src[0..first]);
    @memcpy(new_buf[first .. first + parsed.value.replace.len], parsed.value.replace);
    const rest_start = first + parsed.value.find.len;
    @memcpy(new_buf[first + parsed.value.replace.len .. new_len], src[rest_start..src.len]);

    internal_writes.writeAtomic(inv.workspace, inv.io, parsed.value.path, new_buf) catch |err| {
        return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err));
    };
    return schema.okResult(inv.allocator, inv.call.id, "edited");
}

const EditArgs = struct {
    path: []const u8,
    find: []const u8,
    replace: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "edit: unique replacement succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "hello world" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "edit", .arguments_json = "{\"path\":\"f.txt\",\"find\":\"world\",\"replace\":\"zig\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    var buf: [64]u8 = undefined;
    const b = try tmp.dir.readFile(testing.io, "f.txt", &buf);
    try testing.expectEqualStrings("hello zig", b);
}

test "edit: ambiguous find is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "a a" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c2", .name = "edit", .arguments_json = "{\"path\":\"f.txt\",\"find\":\"a\",\"replace\":\"b\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("edit.ambiguous", result.outcome.err.id);
}

test "edit: no match is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "content" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c3", .name = "edit", .arguments_json = "{\"path\":\"f.txt\",\"find\":\"missing\",\"replace\":\"x\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("edit.no_match", result.outcome.err.id);
}
