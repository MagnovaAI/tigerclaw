//! The layered settings schema.
//!
//! `Settings` is a plain struct that is JSON-parseable, field-validated,
//! and backed by defaults from `constants/defaults.zig`. The loader,
//! env-override layer, and change detector all operate on values of this
//! type.

const std = @import("std");
const defaults = @import("../constants/defaults.zig");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn jsonStringify(self: LogLevel, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !LogLevel {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(LogLevel, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Mode = enum {
    run,
    bench,
    replay,
    eval,

    pub fn jsonStringify(self: Mode, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Mode {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(Mode, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Settings = struct {
    log_level: LogLevel = .info,
    mode: Mode = .run,
    max_tool_iterations: u32 = defaults.max_tool_iterations,
    max_history_messages: u32 = defaults.max_history_messages,
    monthly_budget_cents: u64 = defaults.monthly_budget_cents,
};

/// Returns a `Settings` populated with every default.
pub fn defaultSettings() Settings {
    return .{};
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "defaultSettings: mirrors constants/defaults.zig" {
    const s = defaultSettings();
    try testing.expectEqual(defaults.max_tool_iterations, s.max_tool_iterations);
    try testing.expectEqual(defaults.max_history_messages, s.max_history_messages);
    try testing.expectEqual(defaults.monthly_budget_cents, s.monthly_budget_cents);
    try testing.expectEqual(LogLevel.info, s.log_level);
    try testing.expectEqual(Mode.run, s.mode);
}

test "Settings: JSON roundtrip preserves every field" {
    const s = Settings{
        .log_level = .warn,
        .mode = .bench,
        .max_tool_iterations = 7,
        .max_history_messages = 42,
        .monthly_budget_cents = 1_000,
    };

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, s, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Settings, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(s.log_level, parsed.value.log_level);
    try testing.expectEqual(s.mode, parsed.value.mode);
    try testing.expectEqual(s.max_tool_iterations, parsed.value.max_tool_iterations);
    try testing.expectEqual(s.max_history_messages, parsed.value.max_history_messages);
    try testing.expectEqual(s.monthly_budget_cents, parsed.value.monthly_budget_cents);
}

test "Settings: unknown log_level rejected" {
    const bad = "{\"log_level\":\"trace\",\"mode\":\"run\",\"max_tool_iterations\":1,\"max_history_messages\":1,\"monthly_budget_cents\":0}";
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Settings, testing.allocator, bad, .{}),
    );
}

test "Settings: unknown mode rejected" {
    const bad = "{\"log_level\":\"info\",\"mode\":\"train\",\"max_tool_iterations\":1,\"max_history_messages\":1,\"monthly_budget_cents\":0}";
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Settings, testing.allocator, bad, .{}),
    );
}

test "Settings: partial JSON fills missing fields with defaults" {
    const partial = "{\"log_level\":\"debug\"}";
    const parsed = try std.json.parseFromSlice(
        Settings,
        testing.allocator,
        partial,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try testing.expectEqual(LogLevel.debug, parsed.value.log_level);
    try testing.expectEqual(Mode.run, parsed.value.mode);
    try testing.expectEqual(defaults.max_tool_iterations, parsed.value.max_tool_iterations);
}
