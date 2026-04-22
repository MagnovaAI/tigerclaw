//! Contract tests for the tool registry.
//!
//! Every registered tool must satisfy the same surface: return a
//! `ToolResult` whose `call_id` equals the requested call's id,
//! allocate its outcome strings out of the supplied allocator, and
//! never panic on malformed arguments (always surface a structured
//! `tool.args`/`*` error).
//!
//! These tests run against the batch-1 default set.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const tools = tigerclaw.tools;
const types = tigerclaw.types;

fn setupRegistry(reg: *tools.Registry) !void {
    try tools.registerBatch1(reg);
}

test "registry: batch1 registers read/write/edit/grep/glob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var reg = tools.Registry.init(testing.allocator, testing.io, tmp.dir);
    defer reg.deinit();
    try setupRegistry(&reg);

    const expected_names = [_][]const u8{ "read", "write", "edit", "grep", "glob" };
    for (expected_names) |name| {
        try testing.expect(reg.lookup(name) != null);
    }
}

test "contract: malformed arguments always surface a structured err result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var reg = tools.Registry.init(testing.allocator, testing.io, tmp.dir);
    defer reg.deinit();
    try setupRegistry(&reg);

    const tool_names = [_][]const u8{ "read", "write", "edit", "grep", "glob" };
    for (tool_names) |name| {
        const result = try reg.executor().execute(testing.allocator, .{
            .id = "c1",
            .name = name,
            .arguments_json = "not-json-at-all",
        });
        defer testing.allocator.free(result.call_id);
        defer switch (result.outcome) {
            .ok => |b| testing.allocator.free(b),
            .err => |b| testing.allocator.free(b.detail),
        };

        try testing.expectEqualStrings("c1", result.call_id);
        try testing.expect(result.outcome == .err);
    }
}

test "contract: call_id is echoed back verbatim on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "ok" });

    var reg = tools.Registry.init(testing.allocator, testing.io, tmp.dir);
    defer reg.deinit();
    try setupRegistry(&reg);

    const result = try reg.executor().execute(testing.allocator, .{
        .id = "unique-call-id-42",
        .name = "read",
        .arguments_json = "{\"path\":\"a.txt\"}",
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);
    try testing.expectEqualStrings("unique-call-id-42", result.call_id);
}

test "contract: every registered tool declares a documented Category" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var reg = tools.Registry.init(testing.allocator, testing.io, tmp.dir);
    defer reg.deinit();
    try setupRegistry(&reg);

    for (reg.specs()) |tool| {
        const val = @intFromEnum(tool.spec.category);
        try testing.expect(val >= 1 and val <= 4);
    }
}
