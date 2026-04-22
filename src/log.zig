//! Leveled log facade.
//!
//! This is a thin scaffold so other modules have a stable call site before
//! the full logging subsystem lands. The implementation delegates to
//! `std.log` for now; later commits will swap the sink to write into the
//! trace recorder.

const std = @import("std");

pub const Level = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    pub fn atLeast(self: Level, threshold: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(threshold);
    }
};

var min_level: Level = .info;

pub fn setMinLevel(level: Level) void {
    min_level = level;
}

pub fn getMinLevel() Level {
    return min_level;
}

pub fn enabled(level: Level) bool {
    return level.atLeast(min_level);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (enabled(.debug)) std.log.debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (enabled(.info)) std.log.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (enabled(.warn)) std.log.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (enabled(.err)) std.log.err(fmt, args);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Level.asText" {
    try testing.expectEqualStrings("debug", Level.debug.asText());
    try testing.expectEqualStrings("info", Level.info.asText());
    try testing.expectEqualStrings("warn", Level.warn.asText());
    try testing.expectEqualStrings("error", Level.err.asText());
}

test "Level.atLeast: ordering is debug < info < warn < err" {
    try testing.expect(Level.err.atLeast(.debug));
    try testing.expect(Level.warn.atLeast(.info));
    try testing.expect(!Level.debug.atLeast(.warn));
    try testing.expect(Level.info.atLeast(.info));
}

test "setMinLevel + enabled gate" {
    defer setMinLevel(.info);
    setMinLevel(.warn);
    try testing.expect(!enabled(.info));
    try testing.expect(enabled(.warn));
    try testing.expect(enabled(.err));
}
