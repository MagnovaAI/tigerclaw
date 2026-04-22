//! Atomic file writes.
//!
//! `writeAtomic` writes `bytes` to `sub_path` under `dir` via a temp-file
//! rename so readers never see a torn file. Nothing else in settings
//! mutates the filesystem — every write flows through here.

const std = @import("std");
const Io = std.Io;

pub const WriteError = Io.Dir.CreateFileAtomicError ||
    Io.File.Atomic.ReplaceError ||
    Io.Writer.Error;

pub fn writeAtomic(
    dir: Io.Dir,
    io: Io,
    sub_path: []const u8,
    bytes: []const u8,
) WriteError!void {
    var atomic = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer atomic.deinit(io);

    var buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(io);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeAtomic: writes bytes and makes them readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAtomic(tmp.dir, testing.io, "hello.txt", "hello, atomic world");

    var buf: [64]u8 = undefined;
    const read = try tmp.dir.readFile(testing.io, "hello.txt", &buf);
    try testing.expectEqualStrings("hello, atomic world", read);
}

test "writeAtomic: overwrite replaces prior contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAtomic(tmp.dir, testing.io, "x.txt", "first");
    try writeAtomic(tmp.dir, testing.io, "x.txt", "second");

    var buf: [64]u8 = undefined;
    const read = try tmp.dir.readFile(testing.io, "x.txt", &buf);
    try testing.expectEqualStrings("second", read);
}
