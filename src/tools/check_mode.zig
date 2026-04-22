//! `check_mode` — report the session mode to the agent so it can
//! reason about which side effects are allowed.
//!
//! The runtime wires the mode in via the arguments JSON (the mode
//! is a process-level fact the tool does not read from globals).
//! Arguments: `{"mode": "run|bench|replay|eval"}`.
//! Output: JSON object describing the capability table, so the
//! model can parse it rather than pattern-matching prose.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");
const harness = @import("../harness/root.zig");

pub const spec = schema.ToolSpec{
    .name = "check_mode",
    .description = "Report the session's mode and capability table.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"mode":{"type":"string"}},"required":["mode"]}
    ,
    .category = .compute,
    .tags = &.{"util"},
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

    const mode_tag = std.meta.stringToEnum(harness.Mode, parsed.value.mode) orelse {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "unknown mode");
    };
    const caps = harness.mode_policy.Capabilities.of(mode_tag);
    const payload = try std.fmt.allocPrint(
        inv.allocator,
        "{{\"mode\":\"{s}\",\"live_network\":{},\"wall_clock\":{},\"filesystem_writes\":{},\"subprocess_spawn\":{}}}",
        .{
            @tagName(mode_tag),
            caps.live_network,
            caps.wall_clock,
            caps.filesystem_writes,
            caps.subprocess_spawn,
        },
    );
    defer inv.allocator.free(payload);
    return schema.okResult(inv.allocator, inv.call.id, payload);
}

const Args = struct {
    mode: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "check_mode: run reports every capability true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "check_mode", .arguments_json = "{\"mode\":\"run\"}" },
    });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.ok);
    try testing.expect(std.mem.indexOf(u8, r.outcome.ok, "\"live_network\":true") != null);
    try testing.expect(std.mem.indexOf(u8, r.outcome.ok, "\"wall_clock\":true") != null);
}

test "check_mode: bench reports false for network/clock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "check_mode", .arguments_json = "{\"mode\":\"bench\"}" },
    });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.ok);
    try testing.expect(std.mem.indexOf(u8, r.outcome.ok, "\"live_network\":false") != null);
    try testing.expect(std.mem.indexOf(u8, r.outcome.ok, "\"wall_clock\":false") != null);
}

test "check_mode: unknown mode rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "check_mode", .arguments_json = "{\"mode\":\"ghost\"}" },
    });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.err.detail);
    try testing.expectEqualStrings("tool.args", r.outcome.err.id);
}
