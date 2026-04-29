//! Integration tests for the setup wizard non-interactive path.
//!
//! These tests exercise `tigerclaw setup --non-interactive`, which must:
//!   1. Write a valid config file at <home>/.config/tigerclaw/config.jsonc.
//!   2. Produce a file that parses as valid JSON with correct defaults.
//!   3. Be idempotent — running twice still yields a valid config.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const setup = tigerclaw.cli.commands.setup;
const settings = tigerclaw.settings;

const testing = std.testing;

/// Minimal environment shim that maps HOME to a caller-supplied path.
/// Other keys return null so the wizard uses the HOME-based default path.
const FakeEnv = struct {
    home: []const u8,

    pub fn get(self: *const FakeEnv, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "HOME")) return self.home;
        return null;
    }
};

/// Run setup in non-interactive mode, directing stdout to an allocating sink
/// and stdin from an empty fixed buffer. Returns the expected config path
/// (arena-allocated — no need to free separately when using an arena).
fn runNonInteractive(
    io: std.Io,
    allocator: std.mem.Allocator,
    home: []const u8,
) ![]const u8 {
    // Allocating writer sink for stdout — the summary text is discarded.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Empty stdin — non-interactive mode never reads from it.
    const empty: []const u8 = "";
    var r: std.Io.Reader = .fixed(empty);

    const env = FakeEnv{ .home = home };
    try setup.run(io, allocator, &aw.writer, &r, .{ .non_interactive = true }, &env);

    // Return the expected config file path.
    return std.fs.path.join(allocator, &.{ home, ".config", "tigerclaw", "config.jsonc" });
}

test "setup non-interactive: writes valid config with defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(testing.io, &home_buf);
    const home = home_buf[0..home_len];

    const config_path = try runNonInteractive(testing.io, alloc, home);

    // Read back through the Io Dir API.
    var read_buf: [128 * 1024]u8 = undefined;
    const bytes = blk: {
        var dir = try std.Io.Dir.openDirAbsolute(
            testing.io,
            std.fs.path.dirname(config_path).?,
            .{},
        );
        defer dir.close(testing.io);
        break :blk try dir.readFile(testing.io, std.fs.path.basename(config_path), &read_buf);
    };

    const parsed = try std.json.parseFromSlice(
        settings.Settings,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    // gateway.url must be the default empty string.
    try testing.expectEqualStrings("", parsed.value.gateway.url);

    // agent.timeout_secs must equal the default (60 seconds).
    try testing.expectEqual(@as(u32, 60), parsed.value.agent.timeout_secs);
}

test "setup non-interactive: idempotent — second run also yields valid config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(testing.io, &home_buf);
    const home = home_buf[0..home_len];

    // First run.
    _ = try runNonInteractive(testing.io, alloc, home);

    // Second run over the same path.
    const config_path = try runNonInteractive(testing.io, alloc, home);

    // Must still produce a parseable, valid config.
    var read_buf: [128 * 1024]u8 = undefined;
    const bytes = blk: {
        var dir = try std.Io.Dir.openDirAbsolute(
            testing.io,
            std.fs.path.dirname(config_path).?,
            .{},
        );
        defer dir.close(testing.io);
        break :blk try dir.readFile(testing.io, std.fs.path.basename(config_path), &read_buf);
    };

    const parsed = try std.json.parseFromSlice(
        settings.Settings,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    try testing.expectEqualStrings("", parsed.value.gateway.url);
    try testing.expectEqual(@as(u32, 60), parsed.value.agent.timeout_secs);

    // Validate the config passes the full validator.
    var issues: std.array_list.Aligned(settings.validation.Issue, null) = .empty;
    try issues.ensureTotalCapacity(alloc, 16);
    try settings.validation.validate(alloc, parsed.value, &issues);
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}
