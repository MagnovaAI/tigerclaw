//! `glob` tool — list files in the workspace matching a simple
//! name pattern. Supports `*` as a single-segment wildcard; more
//! elaborate globbing (`**`, character classes) is deferred until
//! a tool actually needs it.
//!
//! Arguments: `{"pattern": "*.zig"}`.
//! Output: newline-separated matched names.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "glob",
    .description = "List workspace files matching a simple '*' pattern.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}
    ,
    .category = .read,
    .tags = &.{"fs"},
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        GlobArgs,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

    var dir = inv.workspace.openDir(inv.io, ".", .{ .iterate = true }) catch |err| {
        return schema.errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err));
    };
    defer dir.close(inv.io);

    var it = dir.iterate();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(inv.allocator);

    while (it.next(inv.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (matches(parsed.value.pattern, entry.name)) {
            try out.appendSlice(inv.allocator, entry.name);
            try out.append(inv.allocator, '\n');
        }
    }

    return schema.okResult(inv.allocator, inv.call.id, out.items);
}

const GlobArgs = struct {
    pattern: []const u8,
};

/// Minimal `*`-glob. Supports zero or more `*`s anywhere in the
/// pattern; other characters must match literally.
fn matches(pattern: []const u8, name: []const u8) bool {
    return matchAt(pattern, 0, name, 0);
}

fn matchAt(pattern: []const u8, pi: usize, name: []const u8, ni: usize) bool {
    if (pi >= pattern.len) return ni >= name.len;
    if (pattern[pi] == '*') {
        // Collapse consecutive *s.
        var pj = pi;
        while (pj < pattern.len and pattern[pj] == '*') : (pj += 1) {}
        // `*` at end of pattern → matches any remainder.
        if (pj >= pattern.len) return true;
        // Try to match the remainder at every suffix of `name`.
        var k = ni;
        while (k <= name.len) : (k += 1) {
            if (matchAt(pattern, pj, name, k)) return true;
        }
        return false;
    }
    if (ni >= name.len) return false;
    if (pattern[pi] != name[ni]) return false;
    return matchAt(pattern, pi + 1, name, ni + 1);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "matches: star at end and middle" {
    try testing.expect(matches("*.zig", "foo.zig"));
    try testing.expect(!matches("*.zig", "foo.txt"));
    try testing.expect(matches("foo*bar", "foo-middle-bar"));
    try testing.expect(matches("*", "anything"));
    try testing.expect(matches("exact", "exact"));
    try testing.expect(!matches("exact", "Exact"));
}

test "glob: returns matching entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "" });

    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "glob", .arguments_json = "{\"pattern\":\"*.zig\"}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);

    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "b.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result.outcome.ok, "notes.txt") == null);
}
