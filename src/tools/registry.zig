//! Tool registry.
//!
//! Owns the set of installed tools keyed by name, exposes a list
//! of specs for prompt-time selection, and implements the
//! `agent.ToolExecutor` interface so the react loop can dispatch
//! by name without knowing how tools are registered.
//!
//! The registry deliberately avoids heap allocation for tool
//! lookup — the tool list is finite and stable over a session, so
//! a linear scan is faster than a hash map in any realistic
//! configuration.

const std = @import("std");
const types = @import("types");
const agent = @import("../agent/root.zig");
const schema_mod = @import("schema.zig");

pub const Error = error{
    DuplicateTool,
    UnknownTool,
} || std.mem.Allocator.Error;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    tools: std.ArrayList(schema_mod.Tool),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace: std.Io.Dir,
    ) Registry {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .tools = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, tool: schema_mod.Tool) Error!void {
        for (self.tools.items) |t| {
            if (std.mem.eql(u8, t.spec.name, tool.spec.name)) return Error.DuplicateTool;
        }
        try self.tools.append(self.allocator, tool);
    }

    pub fn lookup(self: *const Registry, name: []const u8) ?*const schema_mod.Tool {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.spec.name, name)) return t;
        }
        return null;
    }

    pub fn specs(self: *const Registry) []const schema_mod.Tool {
        return self.tools.items;
    }

    /// Adapt the registry to the react loop's `ToolExecutor`.
    pub fn executor(self: *Registry) agent.ToolExecutor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn executeCall(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        call: types.ToolCall,
    ) anyerror!types.ToolResult {
        const self: *Registry = @ptrCast(@alignCast(ctx));
        const tool = self.lookup(call.name) orelse
            return schema_mod.errResult(allocator, call.id, "tool.unknown", call.name);
        return tool.handler(.{
            .allocator = allocator,
            .io = self.io,
            .workspace = self.workspace,
            .call = call,
        });
    }

    const vtable = agent.ToolExecutor.VTable{ .execute = executeCall };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testHandlerOk(inv: schema_mod.Invocation) anyerror!types.ToolResult {
    return schema_mod.okResult(inv.allocator, inv.call.id, "ran");
}

test "Registry: register rejects duplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = Registry.init(testing.allocator, testing.io, tmp.dir);
    defer r.deinit();

    const spec = schema_mod.ToolSpec{
        .name = "echo",
        .description = "",
        .category = .read,
    };
    try r.register(.{ .spec = spec, .handler = testHandlerOk });
    try testing.expectError(
        Error.DuplicateTool,
        r.register(.{ .spec = spec, .handler = testHandlerOk }),
    );
}

test "Registry: executor dispatches by tool name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = Registry.init(testing.allocator, testing.io, tmp.dir);
    defer r.deinit();

    try r.register(.{
        .spec = .{ .name = "echo", .description = "", .category = .read },
        .handler = testHandlerOk,
    });

    const result = try r.executor().execute(testing.allocator, .{
        .id = "c1",
        .name = "echo",
        .arguments_json = "{}",
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.ok);
    try testing.expectEqualStrings("ran", result.outcome.ok);
}

test "Registry: unknown tool returns tool.unknown error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r = Registry.init(testing.allocator, testing.io, tmp.dir);
    defer r.deinit();

    const result = try r.executor().execute(testing.allocator, .{
        .id = "c1",
        .name = "nope",
        .arguments_json = "{}",
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("tool.unknown", result.outcome.err.id);
}
