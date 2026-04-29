//! Full layered load: defaults → file JSON → env overrides.
//!
//! The loader is pure up to the point where it reads a slice of bytes.
//! Callers are responsible for obtaining that slice (via managed_path and
//! a filesystem read). This keeps the loader portable across the build
//! and test environments and avoids threading `Io` through every call
//! site before the I/O subsystem lands.

const std = @import("std");
const schema = @import("schema.zig");
const validation = @import("validation.zig");
const env_overrides = @import("env_overrides.zig");

const Settings = schema.Settings;

pub const LoadError = error{
    InvalidJson,
} || env_overrides.ApplyError || validation.ValidationError;

pub const LoadReport = struct {
    parsed: std.json.Parsed(Settings),

    pub fn value(self: *const LoadReport) Settings {
        return self.parsed.value;
    }

    pub fn deinit(self: *LoadReport) void {
        self.parsed.deinit();
    }
};

/// Parse `bytes` as JSON, apply the supplied env overrides, then validate
/// the result. `bytes` may be empty, in which case the loader returns a
/// `Settings` populated entirely from defaults.
pub fn loadFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    env: env_overrides.Lookup,
) LoadError!LoadReport {
    const source = if (bytes.len == 0) "{}" else bytes;
    var parsed = std.json.parseFromSlice(
        Settings,
        allocator,
        source,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidJson;
    errdefer parsed.deinit();

    try env_overrides.apply(&parsed.value, env);

    var issues: std.array_list.Aligned(validation.Issue, null) = .empty;
    defer issues.deinit(allocator);
    issues.ensureTotalCapacity(allocator, 8) catch {
        return error.InvalidSettings;
    };
    try validation.validate(allocator, parsed.value, &issues);

    return .{ .parsed = parsed };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const MapLookup = env_overrides.MapLookup;

fn emptyEnv() MapLookup {
    return .{ .entries = &.{} };
}

test "loadFromBytes: empty bytes yields defaults" {
    var env = emptyEnv();
    var report = try loadFromBytes(testing.allocator, "", env.lookup());
    defer report.deinit();
    try testing.expectEqual(Settings{}, report.value());
}

test "loadFromBytes: JSON values take effect" {
    const cfg = "{\"log_level\":\"warn\",\"max_tool_iterations\":7}";
    var env = emptyEnv();
    var report = try loadFromBytes(testing.allocator, cfg, env.lookup());
    defer report.deinit();
    try testing.expectEqual(schema.LogLevel.warn, report.value().log_level);
    try testing.expectEqual(@as(u32, 7), report.value().max_tool_iterations);
}

test "loadFromBytes: env overrides JSON" {
    const cfg = "{\"log_level\":\"info\",\"mode\":\"run\"}";
    var env = MapLookup{ .entries = &.{
        .{ .name = env_overrides.prefix ++ "LOG_LEVEL", .value = "debug" },
        .{ .name = env_overrides.prefix ++ "MODE", .value = "bench" },
    } };
    var report = try loadFromBytes(testing.allocator, cfg, env.lookup());
    defer report.deinit();
    try testing.expectEqual(schema.LogLevel.debug, report.value().log_level);
    try testing.expectEqual(schema.Mode.bench, report.value().mode);
}

test "loadFromBytes: malformed JSON returns InvalidJson" {
    var env = emptyEnv();
    try testing.expectError(
        error.InvalidJson,
        loadFromBytes(testing.allocator, "{not json", env.lookup()),
    );
}

test "loadFromBytes: invalid env value surfaces from env layer" {
    var env = MapLookup{ .entries = &.{
        .{ .name = env_overrides.prefix ++ "LOG_LEVEL", .value = "trace" },
    } };
    try testing.expectError(
        error.InvalidEnvValue,
        loadFromBytes(testing.allocator, "{}", env.lookup()),
    );
}

test "loadFromBytes: failed validation surfaces InvalidSettings" {
    const cfg = "{\"max_tool_iterations\":0}";
    var env = emptyEnv();
    try testing.expectError(
        error.InvalidSettings,
        loadFromBytes(testing.allocator, cfg, env.lookup()),
    );
}
