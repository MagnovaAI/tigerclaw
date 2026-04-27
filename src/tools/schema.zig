//! Tool schema — describes one registered tool.
//!
//! Each tool exposes a value of `ToolSpec` that the registry
//! inspects and the provider prompt layer serialises. The spec
//! carries only the metadata every provider needs; concrete
//! argument shapes are decoded inside the tool's handler from
//! the raw JSON string in `ToolCall.arguments_json`.

const std = @import("std");
const types = @import("types");
const sandbox = @import("../sandbox/root.zig");

pub const FsPolicy = sandbox.FsPolicy;

pub const default_workspace_fs_policy = sandbox.FsPolicy{
    .allowlist = &.{"/"},
    .writes_allowed = true,
};

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
    /// Filesystem policy for logical workspace paths. Paths are
    /// normalised as `/<relative-path>` before policy checks so the
    /// default policy allows only the workspace subtree.
    fs_policy: sandbox.FsPolicy = default_workspace_fs_policy,
    call: types.ToolCall,
};

pub const Handler = *const fn (inv: Invocation) anyerror!types.ToolResult;

/// Fully-registered tool: spec + handler.
pub const Tool = struct {
    spec: ToolSpec,
    handler: Handler,
};

pub fn checkWorkspacePath(
    inv: Invocation,
    path: []const u8,
    access: sandbox.fs.Access,
) !?types.ToolResult {
    if (!isWorkspaceRelativePath(path)) {
        return try errResult(inv.allocator, inv.call.id, "fs.path", "path must be workspace-relative");
    }

    const logical = try std.fmt.allocPrint(inv.allocator, "/{s}", .{path});
    defer inv.allocator.free(logical);
    if (sandbox.fs.check(inv.fs_policy, logical, access) == .deny) {
        return try errResult(inv.allocator, inv.call.id, "permissions.denied", path);
    }

    const has_symlink = pathHasSymlink(inv, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try errResult(inv.allocator, inv.call.id, "fs.error", @errorName(err)),
    };
    if (has_symlink) {
        return try errResult(inv.allocator, inv.call.id, "fs.symlink", "symlink paths are not allowed");
    }

    return null;
}

fn isWorkspaceRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.startsWith(u8, path, "/")) return false;
    if (std.mem.startsWith(u8, path, "\\")) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;

    var saw_component = false;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        saw_component = true;
    }
    return saw_component;
}

fn pathHasSymlink(inv: Invocation, path: []const u8) !bool {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(inv.allocator);

    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        try parts.append(inv.allocator, part);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(inv.allocator);

    for (parts.items) |part| {
        if (current.items.len != 0) try current.append(inv.allocator, '/');
        try current.appendSlice(inv.allocator, part);

        const stat = inv.workspace.statFile(inv.io, current.items, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (stat.kind == .sym_link) return true;
    }

    return false;
}

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

test "checkWorkspacePath: rejects absolute and traversal paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const inv = Invocation{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "read", .arguments_json = "{}" },
    };

    const absolute = (try checkWorkspacePath(inv, "/etc/passwd", .read)).?;
    defer testing.allocator.free(absolute.call_id);
    defer testing.allocator.free(absolute.outcome.err.detail);
    try testing.expectEqualStrings("fs.path", absolute.outcome.err.id);

    const traversal = (try checkWorkspacePath(inv, "../secret", .read)).?;
    defer testing.allocator.free(traversal.call_id);
    defer testing.allocator.free(traversal.outcome.err.detail);
    try testing.expectEqualStrings("fs.path", traversal.outcome.err.id);
}

test "checkWorkspacePath: enforces write policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const inv = Invocation{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .fs_policy = .{ .allowlist = &.{"/"} },
        .call = .{ .id = "c1", .name = "write", .arguments_json = "{}" },
    };

    const denied = (try checkWorkspacePath(inv, "out.txt", .write)).?;
    defer testing.allocator.free(denied.call_id);
    defer testing.allocator.free(denied.outcome.err.detail);
    try testing.expectEqualStrings("permissions.denied", denied.outcome.err.id);
}

test "checkWorkspacePath: rejects symlink components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.txt", .data = "target" });
    tmp.dir.symLink(testing.io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };

    const inv = Invocation{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "read", .arguments_json = "{}" },
    };

    const denied = (try checkWorkspacePath(inv, "link.txt", .read)).?;
    defer testing.allocator.free(denied.call_id);
    defer testing.allocator.free(denied.outcome.err.detail);
    try testing.expectEqualStrings("fs.symlink", denied.outcome.err.id);
}
