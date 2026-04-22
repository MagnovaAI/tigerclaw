//! Config path resolution: flag > env > XDG default.
//!
//! The runtime reads its config from a single file. Which file? This
//! module picks it. Precedence:
//!
//!   1. Explicit `--config <path>` flag, if set.
//!   2. `TIGERCLAW_CONFIG` environment variable.
//!   3. `$XDG_CONFIG_HOME/tigerclaw/config.jsonc` when `XDG_CONFIG_HOME` is set.
//!   4. `$HOME/.config/tigerclaw/config.jsonc` otherwise.
//!
//! This module does not touch the filesystem. It composes a path.

const std = @import("std");

pub const Inputs = struct {
    flag: ?[]const u8 = null,
    env_config: ?[]const u8 = null,
    env_xdg: ?[]const u8 = null,
    env_home: ?[]const u8 = null,
};

pub const Source = enum { flag, env, xdg, home };

pub const Resolved = struct {
    path: []u8,
    source: Source,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const ResolveError = error{
    NoCandidate,
    OutOfMemory,
};

pub fn resolve(allocator: std.mem.Allocator, inputs: Inputs) ResolveError!Resolved {
    if (inputs.flag) |f| {
        return .{ .path = try allocator.dupe(u8, f), .source = .flag };
    }
    if (inputs.env_config) |e| {
        return .{ .path = try allocator.dupe(u8, e), .source = .env };
    }
    if (inputs.env_xdg) |xdg| {
        const path = try std.fs.path.join(allocator, &.{ xdg, "tigerclaw", "config.jsonc" });
        return .{ .path = path, .source = .xdg };
    }
    if (inputs.env_home) |home| {
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "tigerclaw", "config.jsonc" });
        return .{ .path = path, .source = .home };
    }
    return error.NoCandidate;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "resolve: flag wins over env and xdg" {
    const r = try resolve(testing.allocator, .{
        .flag = "/cli/here.jsonc",
        .env_config = "/env/here.jsonc",
        .env_xdg = "/xdg",
        .env_home = "/home/me",
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Source.flag, r.source);
    try testing.expectEqualStrings("/cli/here.jsonc", r.path);
}

test "resolve: env beats xdg and home when flag is absent" {
    const r = try resolve(testing.allocator, .{
        .env_config = "/env/here.jsonc",
        .env_xdg = "/xdg",
        .env_home = "/home/me",
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Source.env, r.source);
    try testing.expectEqualStrings("/env/here.jsonc", r.path);
}

test "resolve: xdg joins tigerclaw/config.jsonc onto XDG_CONFIG_HOME" {
    const r = try resolve(testing.allocator, .{
        .env_xdg = "/xdg",
        .env_home = "/home/me",
    });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Source.xdg, r.source);
    try testing.expectEqualStrings("/xdg/tigerclaw/config.jsonc", r.path);
}

test "resolve: home falls back to $HOME/.config" {
    const r = try resolve(testing.allocator, .{ .env_home = "/home/me" });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Source.home, r.source);
    try testing.expectEqualStrings("/home/me/.config/tigerclaw/config.jsonc", r.path);
}

test "resolve: no inputs returns NoCandidate" {
    try testing.expectError(error.NoCandidate, resolve(testing.allocator, .{}));
}
