//! Environment-variable overrides for `Settings`.
//!
//! The loader calls `apply` after parsing the config file but before the
//! runtime installs the settings. Each supported env var maps to exactly
//! one field; unrecognized values surface as `error.InvalidEnvValue`.
//!
//! This module is pure — it takes a `Lookup` (a tiny indirection over
//! `std.process.getEnvVarOwned`) so tests can feed a hand-built env.

const std = @import("std");
const schema = @import("schema.zig");
const Settings = schema.Settings;

pub const prefix = "TIGERCLAW_";

pub const Lookup = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns the value for `name`, or `null` if unset. The returned
        /// slice is borrowed for the duration of the `apply` call.
        get: *const fn (ptr: *anyopaque, name: []const u8) ?[]const u8,
    };

    pub fn get(self: Lookup, name: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, name);
    }
};

pub const ApplyError = error{
    InvalidEnvValue,
};

pub fn apply(s: *Settings, env: Lookup) ApplyError!void {
    if (env.get(prefix ++ "LOG_LEVEL")) |v| {
        s.log_level = std.meta.stringToEnum(schema.LogLevel, v) orelse
            return error.InvalidEnvValue;
    }
    if (env.get(prefix ++ "MODE")) |v| {
        s.mode = std.meta.stringToEnum(schema.Mode, v) orelse
            return error.InvalidEnvValue;
    }
    if (env.get(prefix ++ "MAX_TOOL_ITERATIONS")) |v| {
        s.max_tool_iterations = std.fmt.parseInt(u32, v, 10) catch
            return error.InvalidEnvValue;
    }
    if (env.get(prefix ++ "MAX_HISTORY_MESSAGES")) |v| {
        s.max_history_messages = std.fmt.parseInt(u32, v, 10) catch
            return error.InvalidEnvValue;
    }
    if (env.get(prefix ++ "MONTHLY_BUDGET_CENTS")) |v| {
        s.monthly_budget_cents = std.fmt.parseInt(u64, v, 10) catch
            return error.InvalidEnvValue;
    }
}

// --- test helpers ----------------------------------------------------------

/// Minimal in-memory env for tests. Caller owns the entries slice.
pub const MapLookup = struct {
    entries: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn lookup(self: *MapLookup) Lookup {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn get(ptr: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *MapLookup = @ptrCast(@alignCast(ptr));
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    const vtable = Lookup.VTable{ .get = get };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "apply: empty env leaves settings unchanged" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{} };
    try apply(&s, env.lookup());
    try testing.expectEqual(Settings{}, s);
}

test "apply: LOG_LEVEL overrides log_level" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "LOG_LEVEL", .value = "warn" },
    } };
    try apply(&s, env.lookup());
    try testing.expectEqual(schema.LogLevel.warn, s.log_level);
}

test "apply: MODE overrides mode" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "MODE", .value = "bench" },
    } };
    try apply(&s, env.lookup());
    try testing.expectEqual(schema.Mode.bench, s.mode);
}

test "apply: numeric overrides parse decimal" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "MAX_TOOL_ITERATIONS", .value = "7" },
        .{ .name = prefix ++ "MAX_HISTORY_MESSAGES", .value = "42" },
        .{ .name = prefix ++ "MONTHLY_BUDGET_CENTS", .value = "1500" },
    } };
    try apply(&s, env.lookup());
    try testing.expectEqual(@as(u32, 7), s.max_tool_iterations);
    try testing.expectEqual(@as(u32, 42), s.max_history_messages);
    try testing.expectEqual(@as(u64, 1500), s.monthly_budget_cents);
}

test "apply: unknown enum value fails with InvalidEnvValue" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "LOG_LEVEL", .value = "trace" },
    } };
    try testing.expectError(error.InvalidEnvValue, apply(&s, env.lookup()));
}

test "apply: non-numeric integer fails with InvalidEnvValue" {
    var s = Settings{};
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "MAX_TOOL_ITERATIONS", .value = "lots" },
    } };
    try testing.expectError(error.InvalidEnvValue, apply(&s, env.lookup()));
}
