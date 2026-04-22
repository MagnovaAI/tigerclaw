//! Tool schema — describes one registered tool.
//!
//! Each tool exposes a value of `ToolSpec` that the registry
//! inspects and the provider prompt layer serialises. The spec
//! carries only the metadata every provider needs; concrete
//! argument shapes are decoded inside the tool's handler from
//! the raw JSON string in `ToolCall.arguments_json`.

const std = @import("std");
const types = @import("../types/root.zig");

/// Tool category — drives both prompt-time selection and the
/// Commit 41 "justification lint" that ensures every registered
/// tool declares what kind of action it performs. Numeric values
/// correspond to documented categories:
///
///   1. read/observe — pure reads, no side effects on the host.
///   2. mutate/write — modifies local state.
///   3. compute — no host I/O; pure helpers (hash, gen id).
///   4. control — alters agent control flow (ask_user, todo_write).
pub const Category = enum(u8) {
    read = 1,
    write = 2,
    compute = 3,
    control = 4,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// JSON-encoded JSON-schema object for the tool's arguments.
    /// The registry does not parse this — providers embed it into
    /// their tool-use wire format verbatim.
    arguments_schema_json: []const u8 = "{}",
    category: Category,
    /// Canonical tags for selection (see `agent.tool_selection`).
    tags: []const []const u8 = &.{},
};

/// Arguments passed to every handler call. `allocator` is where
/// the handler should place any strings it puts into the
/// `ToolResult` — the agent react loop owns them after the call
/// returns.
pub const Invocation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// State directory-ish root the tool may touch. Tools that
    /// need multi-path access should refuse and surface an error;
    /// anything richer lives with real sandboxing (Commit 29).
    workspace: std.Io.Dir,
    call: types.ToolCall,
};

pub const Handler = *const fn (inv: Invocation) anyerror!types.ToolResult;

/// Fully-registered tool: spec + handler.
pub const Tool = struct {
    spec: ToolSpec,
    handler: Handler,
};

pub fn okResult(allocator: std.mem.Allocator, call_id: []const u8, payload: []const u8) !types.ToolResult {
    const id_copy = try allocator.dupe(u8, call_id);
    errdefer allocator.free(id_copy);
    const payload_copy = try allocator.dupe(u8, payload);
    return .{ .call_id = id_copy, .outcome = .{ .ok = payload_copy } };
}

pub fn errResult(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    err_id: []const u8,
    detail: []const u8,
) !types.ToolResult {
    const id_copy = try allocator.dupe(u8, call_id);
    errdefer allocator.free(id_copy);
    const detail_copy = try allocator.dupe(u8, detail);
    return .{
        .call_id = id_copy,
        .outcome = .{ .err = .{ .id = err_id, .detail = detail_copy } },
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Category: enum values match documented numbering" {
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Category.read));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Category.write));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Category.compute));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Category.control));
}

test "okResult / errResult produce owning strings" {
    const ok = try okResult(testing.allocator, "c1", "hi");
    defer testing.allocator.free(ok.call_id);
    defer testing.allocator.free(ok.outcome.ok);
    try testing.expectEqualStrings("c1", ok.call_id);
    try testing.expectEqualStrings("hi", ok.outcome.ok);

    const err = try errResult(testing.allocator, "c2", "x.y", "nope");
    defer testing.allocator.free(err.call_id);
    defer testing.allocator.free(err.outcome.err.detail);
    try testing.expectEqualStrings("x.y", err.outcome.err.id);
}
