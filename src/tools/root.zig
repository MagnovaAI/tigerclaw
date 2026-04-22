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
}
