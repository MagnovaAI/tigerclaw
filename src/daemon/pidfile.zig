//! PID-file management for the gateway daemon.
//!
//! A running gateway writes its process id into a well-known file so
//! that follow-up commands (`gateway stop`, `gateway status`) know
//! who to signal. This module keeps the file handling separate from
//! the fork/detach logic so it is testable without spawning a child.
//!
//! Semantics match the common Unix convention:
//!   - `write(path, pid)` creates the file; truncates any existing
//!     contents (callers should check staleness first).
//!   - `read(path)` returns the pid as a `i32` or a specific error
//!     (`FileMissing`, `Corrupt`, `IoFailure`).
//!   - `isStale(path)` returns true when the file references a pid
//!     that does not exist on the host; the caller treats that as
//!     permission to overwrite.
//!   - `remove(path)` unlinks; a missing file is not an error.
//!
//! Every op takes an `io: std.Io` plus an owning `Dir` so tests wire
//! a `tmpDir` without touching `/var/run`.

const std = @import("std");
const builtin = @import("builtin");

pub const ReadError = error{
    FileMissing,
    Corrupt,
    IoFailure,
};

pub const WriteError = error{
    IoFailure,
};

pub const Pid = i32;

/// Write `pid` to `path` inside `dir`. Truncates any existing file.
pub fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, pid: Pid) WriteError!void {
    const file = dir.createFile(io, path, .{ .truncate = true }) catch return error.IoFailure;
    defer file.close(io);

    var buf: [16]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return error.IoFailure;

    var w_buf: [32]u8 = undefined;
    var w = file.writer(io, &w_buf);
    w.interface.writeAll(rendered) catch return error.IoFailure;
    w.interface.flush() catch return error.IoFailure;
}

/// Read a pid value from `path` inside `dir`. Returns a typed error
/// when the file is missing or does not contain a valid integer.
pub fn read(io: std.Io, dir: std.Io.Dir, path: []const u8) ReadError!Pid {
    const file = dir.openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return error.FileMissing,
        else => return error.IoFailure,
    };
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var r_buf: [32]u8 = undefined;
    var r = file.reader(io, &r_buf);
    const n = r.interface.readSliceShort(&buf) catch return error.IoFailure;

    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return error.Corrupt;
    const pid = std.fmt.parseInt(Pid, trimmed, 10) catch return error.Corrupt;
    return pid;
}

pub const RemoveError = error{IoFailure};

/// Remove the PID file. Missing files return successfully — stop
/// paths call this unconditionally after signalling.
pub fn remove(io: std.Io, dir: std.Io.Dir, path: []const u8) RemoveError!void {
    dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.IoFailure,
    };
}

/// Returns true when the pid recorded in `path` does not correspond
/// to a running process on the host. A missing file is also treated
/// as "stale".
///
/// Uses `kill(pid, 0)` to probe liveness; sending signal zero performs
/// the permission check without delivering anything.
pub fn isStale(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const pid = read(io, dir, path) catch |err| switch (err) {
        error.FileMissing => return true,
        error.Corrupt, error.IoFailure => return true,
    };
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return false;
    }
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return true,
        error.PermissionDenied => return false,
        else => return false,
    };
    return false;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "write then read round-trips a pid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(testing.io, tmp.dir, "tigerclaw.pid", 12345);
    const got = try read(testing.io, tmp.dir, "tigerclaw.pid");
    try testing.expectEqual(@as(Pid, 12345), got);
}

test "read on a missing file returns FileMissing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileMissing, read(testing.io, tmp.dir, "absent.pid"));
}

test "read of a corrupt file returns Corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(testing.io, "bad.pid", .{});
    defer file.close(testing.io);
    var buf: [16]u8 = undefined;
    var w = file.writer(testing.io, &buf);
    try w.interface.writeAll("not-a-number\n");
    try w.interface.flush();

    try testing.expectError(error.Corrupt, read(testing.io, tmp.dir, "bad.pid"));
}

test "remove is a no-op on a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try remove(testing.io, tmp.dir, "absent.pid");
}

test "isStale returns true for a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(isStale(testing.io, tmp.dir, "absent.pid"));
}

test "isStale returns true for an obviously-dead pid" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Process 1 is typically `init` and always alive; pick something
    // extremely unlikely to be a running pid instead.
    try write(testing.io, tmp.dir, "dead.pid", 2_000_000_000);
    try testing.expect(isStale(testing.io, tmp.dir, "dead.pid"));
}

test "isStale returns false for the current process" {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // std.os.linux / darwin expose getpid; in 0.16 it lives on
    // posix as `getpid()`.
    const self_pid: Pid = @intCast(std.c.getpid());
    try write(testing.io, tmp.dir, "live.pid", self_pid);
    try testing.expect(!isStale(testing.io, tmp.dir, "live.pid"));
}
