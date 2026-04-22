//! MDM-managed overrides.
//!
//! Placeholder for the layer that applies settings pushed by mobile-
//! device-management policy (macOS configuration profiles, Windows group
//! policy). The contract is: MDM values are the final overlay and cannot
//! be overridden by env vars, flags, or runtime patches.
//!
//! Today this module only defines the interface. A later commit wires an
//! OS-specific backend.

const std = @import("std");
const schema = @import("schema.zig");
const Settings = schema.Settings;

pub const Overrides = struct {
    log_level: ?schema.LogLevel = null,
    mode: ?schema.Mode = null,
    max_tool_iterations: ?u32 = null,
    max_history_messages: ?u32 = null,
    monthly_budget_cents: ?u64 = null,
};

/// Applies `overrides` to `s` in place. Any field set in `overrides`
/// replaces the corresponding field in `s`.
pub fn applyOverrides(s: *Settings, overrides: Overrides) void {
    if (overrides.log_level) |v| s.log_level = v;
    if (overrides.mode) |v| s.mode = v;
    if (overrides.max_tool_iterations) |v| s.max_tool_iterations = v;
    if (overrides.max_history_messages) |v| s.max_history_messages = v;
    if (overrides.monthly_budget_cents) |v| s.monthly_budget_cents = v;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "applyOverrides: all-null is a no-op" {
    var s = Settings{};
    const before = s;
    applyOverrides(&s, .{});
    try testing.expectEqual(before, s);
}

test "applyOverrides: set fields override" {
    var s = Settings{};
    applyOverrides(&s, .{ .log_level = .warn, .mode = .bench });
    try testing.expectEqual(schema.LogLevel.warn, s.log_level);
    try testing.expectEqual(schema.Mode.bench, s.mode);
}

test "applyOverrides: unset fields are preserved" {
    var s = Settings{ .log_level = .debug, .mode = .eval, .max_tool_iterations = 9 };
    applyOverrides(&s, .{ .max_tool_iterations = 1 });
    try testing.expectEqual(schema.LogLevel.debug, s.log_level);
    try testing.expectEqual(schema.Mode.eval, s.mode);
    try testing.expectEqual(@as(u32, 1), s.max_tool_iterations);
}
