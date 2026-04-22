//! Tool subsystem: registry + per-tool modules.
//!
//! Each tool lives in its own file so its spec, handler, and
//! tests sit together. The registry owns the set of registered
//! tools and adapts to `agent.ToolExecutor`.
//!
//! Batch-1 tools (Commit 39): read, write, edit, grep, glob.
//! Batch-2 (bash, apply_patch, task_delegate, ask_user, todo_write)
//! and shim tools (Commit 41) register through the same surface.

const std = @import("std");

pub const schema = @import("schema.zig");
pub const registry = @import("registry.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");
pub const edit = @import("edit.zig");
pub const grep = @import("grep.zig");
pub const glob = @import("glob.zig");
pub const bash = @import("bash.zig");
pub const apply_patch = @import("apply_patch.zig");
pub const task_delegate = @import("task_delegate.zig");
pub const ask_user = @import("ask_user.zig");
pub const todo_write = @import("todo_write.zig");
pub const clock_now = @import("clock_now.zig");
pub const gen_id = @import("gen_id.zig");
pub const random_seeded = @import("random_seeded.zig");
pub const check_mode = @import("check_mode.zig");
pub const cost_check = @import("cost_check.zig");
pub const token_count = @import("token_count.zig");

pub const ToolSpec = schema.ToolSpec;
pub const Tool = schema.Tool;
pub const Category = schema.Category;
pub const Invocation = schema.Invocation;
pub const Registry = registry.Registry;

/// Register the batch-1 core tools onto `reg`. Tools can also be
/// registered individually; this helper is a convenience for
/// callers that want the default set.
pub fn registerBatch1(reg: *Registry) !void {
    try reg.register(.{ .spec = read.spec, .handler = read.handler });
    try reg.register(.{ .spec = write.spec, .handler = write.handler });
    try reg.register(.{ .spec = edit.spec, .handler = edit.handler });
    try reg.register(.{ .spec = grep.spec, .handler = grep.handler });
    try reg.register(.{ .spec = glob.spec, .handler = glob.handler });
}

/// Register the batch-2 tools (bash, apply_patch, task_delegate,
/// ask_user, todo_write).
pub fn registerBatch2(reg: *Registry) !void {
    try reg.register(.{ .spec = bash.spec, .handler = bash.handler });
    try reg.register(.{ .spec = apply_patch.spec, .handler = apply_patch.handler });
    try reg.register(.{ .spec = task_delegate.spec, .handler = task_delegate.handler });
    try reg.register(.{ .spec = ask_user.spec, .handler = ask_user.handler });
    try reg.register(.{ .spec = todo_write.spec, .handler = todo_write.handler });
}

/// Register the shim tools (Commit 41): small deterministic
/// compute helpers plus the two mode/cost reporters.
pub fn registerShims(reg: *Registry) !void {
    try reg.register(.{ .spec = clock_now.spec, .handler = clock_now.handler });
    try reg.register(.{ .spec = gen_id.spec, .handler = gen_id.handler });
    try reg.register(.{ .spec = random_seeded.spec, .handler = random_seeded.handler });
    try reg.register(.{ .spec = check_mode.spec, .handler = check_mode.handler });
    try reg.register(.{ .spec = cost_check.spec, .handler = cost_check.handler });
    try reg.register(.{ .spec = token_count.spec, .handler = token_count.handler });
}

/// Every built-in tool, as a `[]const Tool` slice. Used by the
/// Commit 41 justification lint to enumerate what must declare a
/// category.
pub fn builtinTools() []const Tool {
    const all = struct {
        const list = [_]Tool{
            .{ .spec = read.spec, .handler = read.handler },
            .{ .spec = write.spec, .handler = write.handler },
            .{ .spec = edit.spec, .handler = edit.handler },
            .{ .spec = grep.spec, .handler = grep.handler },
            .{ .spec = glob.spec, .handler = glob.handler },
            .{ .spec = bash.spec, .handler = bash.handler },
            .{ .spec = apply_patch.spec, .handler = apply_patch.handler },
            .{ .spec = task_delegate.spec, .handler = task_delegate.handler },
            .{ .spec = ask_user.spec, .handler = ask_user.handler },
            .{ .spec = todo_write.spec, .handler = todo_write.handler },
            .{ .spec = clock_now.spec, .handler = clock_now.handler },
            .{ .spec = gen_id.spec, .handler = gen_id.handler },
            .{ .spec = random_seeded.spec, .handler = random_seeded.handler },
            .{ .spec = check_mode.spec, .handler = check_mode.handler },
            .{ .spec = cost_check.spec, .handler = cost_check.handler },
            .{ .spec = token_count.spec, .handler = token_count.handler },
        };
    };
    return &all.list;
}

test {
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("registry.zig"));
    std.testing.refAllDecls(@import("read.zig"));
    std.testing.refAllDecls(@import("write.zig"));
    std.testing.refAllDecls(@import("edit.zig"));
    std.testing.refAllDecls(@import("grep.zig"));
    std.testing.refAllDecls(@import("glob.zig"));
    std.testing.refAllDecls(@import("bash.zig"));
    std.testing.refAllDecls(@import("apply_patch.zig"));
    std.testing.refAllDecls(@import("task_delegate.zig"));
    std.testing.refAllDecls(@import("ask_user.zig"));
    std.testing.refAllDecls(@import("todo_write.zig"));
    std.testing.refAllDecls(@import("clock_now.zig"));
    std.testing.refAllDecls(@import("gen_id.zig"));
    std.testing.refAllDecls(@import("random_seeded.zig"));
    std.testing.refAllDecls(@import("check_mode.zig"));
    std.testing.refAllDecls(@import("cost_check.zig"));
    std.testing.refAllDecls(@import("token_count.zig"));
}
