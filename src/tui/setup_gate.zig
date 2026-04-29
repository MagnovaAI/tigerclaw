//! Detects whether `tigerclaw setup` needs to run before the TUI starts.
//!
//! A config is considered "ready" when the config file exists, is valid JSON,
//! and has at least one of: gateway.url non-empty OR provider.name non-empty.
//! Any failure to read or parse the file is treated as "not configured".

const std = @import("std");
const schema = @import("../settings/schema.zig");
const managed_path = @import("../settings/managed_path.zig");

pub const Status = union(enum) {
    ready,
    setup_required: Reason,
};

pub const Reason = enum {
    no_config_file,
    no_gateway_or_provider,
};

/// Check whether the TUI can start without running `tigerclaw setup`.
///
/// `io` is a `std.Io` value. `allocator` is used for path resolution only.
/// `environ` is any type that responds to `.get([]const u8) ?[]const u8`
/// (e.g. `*std.process.Environ.Map`).
pub fn check(io: std.Io, allocator: std.mem.Allocator, environ: anytype) Status {
    // Resolve the config path. If no candidate exists (no HOME, no env vars)
    // we treat the situation as a missing config file.
    const resolved = managed_path.resolve(allocator, .{
        .env_config = environ.get("TIGERCLAW_CONFIG"),
        .env_xdg = environ.get("XDG_CONFIG_HOME"),
        .env_home = environ.get("HOME"),
    }) catch return .{ .setup_required = .no_config_file };
    defer resolved.deinit(allocator);

    // Open the parent directory and read the config file. Any I/O error
    // (file missing, permission denied, etc.) means "not configured".
    const dir_path = std.fs.path.dirname(resolved.path) orelse ".";
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch
        return .{ .setup_required = .no_config_file };
    defer dir.close(io);

    const filename = std.fs.path.basename(resolved.path);
    var buf: [128 * 1024]u8 = undefined;
    const bytes = dir.readFile(io, filename, &buf) catch
        return .{ .setup_required = .no_config_file };

    // Parse as Settings. Unknown fields are silently ignored so future schema
    // additions don't break older binaries reading a newer config.
    const parsed = std.json.parseFromSlice(
        schema.Settings,
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return .{ .setup_required = .no_config_file };
    defer parsed.deinit();

    const s = parsed.value;

    // At least one of gateway.url or provider.name must be non-empty for the
    // TUI to have a useful endpoint to talk to.
    if (s.gateway.url.len > 0 or s.provider.name.len > 0) {
        return .ready;
    }

    return .{ .setup_required = .no_gateway_or_provider };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const writer = @import("../settings/writer.zig");

/// Minimal env map for tests: a slice of name/value pairs.
const FakeEnv = struct {
    entries: []const [2][]const u8,

    pub fn get(self: FakeEnv, key: []const u8) ?[]const u8 {
        for (self.entries) |kv| {
            if (std.mem.eql(u8, kv[0], key)) return kv[1];
        }
        return null;
    }
};

test "check: missing config file → setup_required(.no_config_file)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(testing.io, &home_buf);
    const home = home_buf[0..home_len];

    // Point HOME at the tmp dir — no config file exists there.
    const env = FakeEnv{ .entries = &.{.{ "HOME", home }} };

    const status = check(testing.io, testing.allocator, env);
    try testing.expectEqual(Reason.no_config_file, switch (status) {
        .setup_required => |r| r,
        .ready => return error.UnexpectedReady,
    });
}

test "check: config with gateway.url set → ready" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(testing.io, &home_buf);
    const home = home_buf[0..home_len];

    // Build the absolute config path and write it using the settings writer
    // (which also creates parent directories).
    const config_path = try std.fs.path.join(
        testing.allocator,
        &.{ home, ".config", "tigerclaw", "config.jsonc" },
    );
    defer testing.allocator.free(config_path);

    const s = schema.Settings{
        .gateway = .{ .url = "http://localhost:8765", .token = "" },
        .provider = .{ .name = "", .model = "" },
    };
    try writer.writeToPath(testing.io, testing.allocator, s, config_path);

    const env = FakeEnv{ .entries = &.{.{ "HOME", home }} };
    const status = check(testing.io, testing.allocator, env);
    try testing.expectEqual(Status.ready, status);
}

test "check: config with empty gateway and empty provider → setup_required(.no_gateway_or_provider)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(testing.io, &home_buf);
    const home = home_buf[0..home_len];

    // Write a config file where both gateway.url and provider.name are empty.
    const config_path = try std.fs.path.join(
        testing.allocator,
        &.{ home, ".config", "tigerclaw", "config.jsonc" },
    );
    defer testing.allocator.free(config_path);

    const s = schema.Settings{
        .gateway = .{ .url = "", .token = "" },
        .provider = .{ .name = "", .model = "" },
    };
    try writer.writeToPath(testing.io, testing.allocator, s, config_path);

    const env = FakeEnv{ .entries = &.{.{ "HOME", home }} };
    const status = check(testing.io, testing.allocator, env);
    try testing.expectEqual(Reason.no_gateway_or_provider, switch (status) {
        .setup_required => |r| r,
        .ready => return error.UnexpectedReady,
    });
}
