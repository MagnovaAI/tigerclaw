//! Atomic config file writer.
//!
//! Serializes a `Settings` value to JSON and writes it to the resolved
//! config path. The write is atomic: content is committed via
//! `internal_writes.writeAtomic`, which renames a temp file into place,
//! so the destination is never in a partial state. Parent directories are
//! created as needed before the write.

const std = @import("std");
const Io = std.Io;
const schema = @import("schema.zig");
const internal_writes = @import("internal_writes.zig");

pub const WriteError = error{
    OutOfMemory,
    MkdirFailed,
    WriteFailed,
};

/// Write `settings` as indented JSON to the file at `path`, creating
/// parent directories as needed. `path` must be absolute. The write is
/// atomic — the destination is never in a partial state.
pub fn writeToPath(
    io: Io,
    allocator: std.mem.Allocator,
    settings: schema.Settings,
    path: []const u8,
) WriteError!void {
    // Serialize first — if allocation fails we haven't touched the FS.
    const json_bytes = std.json.Stringify.valueAlloc(allocator, settings, .{ .whitespace = .indent_2 }) catch
        return error.OutOfMemory;
    defer allocator.free(json_bytes);

    // Ensure parent directory exists. `createDirPath` handles nested paths
    // and is a no-op when the directory already exists.
    const dir_path = std.fs.path.dirname(path) orelse ".";
    Io.Dir.cwd().createDirPath(io, dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.MkdirFailed,
    };

    // Open the parent dir so writeAtomic can do the rename within it.
    var parent = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.WriteFailed;
    defer parent.close(io);

    const filename = std.fs.path.basename(path);
    internal_writes.writeAtomic(parent, io, filename, json_bytes) catch return error.WriteFailed;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeToPath: roundtrip preserves gateway and provider" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get absolute path of the tmp dir.
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &base_buf);
    const base = base_buf[0..base_len];

    const path = try std.fs.path.join(testing.allocator, &.{ base, "tigerclaw", "config.jsonc" });
    defer testing.allocator.free(path);

    const s = schema.Settings{
        .gateway = .{ .url = "http://localhost:8765", .token = "tok" },
        .provider = .{ .name = "anthropic", .model = "claude-opus-4-7" },
    };

    try writeToPath(testing.io, testing.allocator, s, path);

    // Read back and parse.
    var buf: [1024 * 64]u8 = undefined;
    const read_back = try tmp.dir.readFile(testing.io, "tigerclaw/config.jsonc", &buf);

    const parsed = try std.json.parseFromSlice(schema.Settings, testing.allocator, read_back, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expectEqualStrings("http://localhost:8765", parsed.value.gateway.url);
    try testing.expectEqualStrings("tok", parsed.value.gateway.token);
    try testing.expectEqualStrings("anthropic", parsed.value.provider.name);
}

test "writeToPath: creates parent directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &base_buf);
    const base = base_buf[0..base_len];

    // Single-level subdir that does not exist yet.
    const path = try std.fs.path.join(testing.allocator, &.{ base, "subdir", "config.jsonc" });
    defer testing.allocator.free(path);

    try writeToPath(testing.io, testing.allocator, schema.Settings{}, path);

    // Verify file is readable through the tmp dir handle.
    var buf: [1024]u8 = undefined;
    const read_back = try tmp.dir.readFile(testing.io, "subdir/config.jsonc", &buf);
    try testing.expect(read_back.len > 0);
}

test "writeToPath: overwrite leaves file consistent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &base_buf);
    const base = base_buf[0..base_len];

    const path = try std.fs.path.join(testing.allocator, &.{ base, "config.jsonc" });
    defer testing.allocator.free(path);

    // First write.
    try writeToPath(testing.io, testing.allocator, schema.Settings{ .gateway = .{ .token = "first" } }, path);
    // Second write overwrites atomically.
    try writeToPath(testing.io, testing.allocator, schema.Settings{ .gateway = .{ .token = "second" } }, path);

    var buf: [1024 * 64]u8 = undefined;
    const read_back = try tmp.dir.readFile(testing.io, "config.jsonc", &buf);
    const parsed = try std.json.parseFromSlice(schema.Settings, testing.allocator, read_back, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expectEqualStrings("second", parsed.value.gateway.token);
}
