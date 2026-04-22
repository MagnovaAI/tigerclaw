//! The outcome of running a tool.
//!
//! A result is either `ok` with the rendered payload, or `err` with a
//! canonical error id (see `errors.zig`) plus a free-form detail string.

const std = @import("std");

pub const ToolResult = struct {
    call_id: []const u8,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        ok: []const u8,
        err: ErrBody,
    };

    pub const ErrBody = struct {
        id: []const u8,
        detail: []const u8,
    };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "ToolResult.ok: stringify includes the rendered payload" {
    const r = ToolResult{
        .call_id = "c1",
        .outcome = .{ .ok = "file contents" },
    };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, r, .{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"file contents\"") != null);
}

test "ToolResult.err: stringify includes id and detail" {
    const r = ToolResult{
        .call_id = "c2",
        .outcome = .{ .err = .{ .id = "not_found", .detail = "no such file" } },
    };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, r, .{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\"not_found\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"no such file\"") != null);
}
