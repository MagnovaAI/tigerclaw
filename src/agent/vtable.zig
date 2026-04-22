//! Tool-executor vtable.
//!
//! The react loop never calls a tool directly — it dispatches
//! through this interface. A `ToolExecutor` takes one `ToolCall`
//! and returns a `ToolResult`. The executor is responsible for
//! argument decoding, permission/sandbox checks, running the tool,
//! and rendering the payload back into a string the LLM can
//! consume.
//!
//! Real executors land later (Commit 39: tool registry + core
//! tools). For this commit the interface exists so the loop can
//! be written and tested against a scripted executor without
//! waiting for the registry.

const std = @import("std");
const types = @import("../types/root.zig");

pub const ToolExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Execute a single tool call.
        ///
        /// The executor must allocate `ToolResult.outcome.ok` /
        /// `ToolResult.outcome.err.detail` out of `allocator`. The
        /// caller (the react loop) owns the returned strings for
        /// the rest of the session's lifetime, so executors must
        /// not keep pointers into `call`.
        execute: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            call: types.ToolCall,
        ) anyerror!types.ToolResult,
    };

    pub fn execute(
        self: ToolExecutor,
        allocator: std.mem.Allocator,
        call: types.ToolCall,
    ) anyerror!types.ToolResult {
        return self.vtable.execute(self.ptr, allocator, call);
    }
};

/// Convenience executor that always returns an `err` result.
/// Used as a safe default when the runtime is configured without
/// tools but the agent code still compiles against the loop.
pub const DenyExecutor = struct {
    pub fn executor(self: *DenyExecutor) ToolExecutor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        call: types.ToolCall,
    ) anyerror!types.ToolResult {
        const call_id_copy = try allocator.dupe(u8, call.id);
        errdefer allocator.free(call_id_copy);
        const detail = try allocator.dupe(u8, "no tool executor is configured for this session");
        return .{
            .call_id = call_id_copy,
            .outcome = .{ .err = .{ .id = "tool.unavailable", .detail = detail } },
        };
    }

    const vtable = ToolExecutor.VTable{ .execute = execute };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "DenyExecutor: emits a structured err outcome for any call" {
    var d = DenyExecutor{};
    const r = try d.executor().execute(
        testing.allocator,
        .{ .id = "c1", .name = "x", .arguments_json = "{}" },
    );
    defer testing.allocator.free(r.call_id);
    defer switch (r.outcome) {
        .ok => |b| testing.allocator.free(b),
        .err => |b| testing.allocator.free(b.detail),
    };

    try testing.expectEqualStrings("c1", r.call_id);
    try testing.expect(r.outcome == .err);
    try testing.expectEqualStrings("tool.unavailable", r.outcome.err.id);
}
