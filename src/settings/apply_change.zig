//! Safe, atomic application of a single-field settings change.
//!
//! A `Patch` names exactly one field; the applier validates the resulting
//! `Settings` before installing it into the cache. Either the whole
//! change lands or nothing does — there is no partial state.

const std = @import("std");
const schema = @import("schema.zig");
const validation = @import("validation.zig");
const cache_mod = @import("cache.zig");

const Settings = schema.Settings;
const Cache = cache_mod.Cache;

pub const Patch = union(enum) {
    log_level: schema.LogLevel,
    mode: schema.Mode,
    max_tool_iterations: u32,
    max_history_messages: u32,
    monthly_budget_cents: u64,
};

pub const ApplyError = validation.ValidationError;

/// Apply `patch` to `c.current`, validate the result, and install it.
/// On failure the cache is unchanged.
pub fn apply(
    allocator: std.mem.Allocator,
    c: *Cache,
    patch: Patch,
) ApplyError!void {
    var next = c.current;
    switch (patch) {
        .log_level => |v| next.log_level = v,
        .mode => |v| next.mode = v,
        .max_tool_iterations => |v| next.max_tool_iterations = v,
        .max_history_messages => |v| next.max_history_messages = v,
        .monthly_budget_cents => |v| next.monthly_budget_cents = v,
    }

    var issues: std.array_list.Aligned(validation.Issue, null) = .empty;
    defer issues.deinit(allocator);
    issues.ensureTotalCapacity(allocator, 4) catch {
        // OOM during validation — treat as invalid.
        return error.InvalidSettings;
    };
    try validation.validate(allocator, next, &issues);

    c.install(next);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "apply: valid patch installs and bumps generation" {
    var c = Cache.init();
    try apply(testing.allocator, &c, .{ .log_level = .warn });
    try testing.expectEqual(schema.LogLevel.warn, c.get().log_level);
    try testing.expectEqual(@as(u64, 1), c.generation);
}

test "apply: invalid patch leaves cache unchanged" {
    var c = Cache.init();
    const before = c.get();
    try testing.expectError(
        error.InvalidSettings,
        apply(testing.allocator, &c, .{ .max_tool_iterations = 0 }),
    );
    try testing.expectEqual(before, c.get());
    try testing.expectEqual(@as(u64, 0), c.generation);
}

test "apply: patch affects only the named field" {
    var c = Cache.init();
    try apply(testing.allocator, &c, .{ .mode = .bench });
    const after = c.get();
    try testing.expectEqual(schema.Mode.bench, after.mode);
    try testing.expectEqual(schema.LogLevel.info, after.log_level);
    try testing.expectEqual(
        @import("../constants/defaults.zig").max_tool_iterations,
        after.max_tool_iterations,
    );
}

test "apply: successive valid patches compose" {
    var c = Cache.init();
    try apply(testing.allocator, &c, .{ .log_level = .warn });
    try apply(testing.allocator, &c, .{ .mode = .bench });
    try apply(testing.allocator, &c, .{ .max_tool_iterations = 12 });
    try testing.expectEqual(@as(u64, 3), c.generation);
    const s = c.get();
    try testing.expectEqual(schema.LogLevel.warn, s.log_level);
    try testing.expectEqual(schema.Mode.bench, s.mode);
    try testing.expectEqual(@as(u32, 12), s.max_tool_iterations);
}
