//! Poll-based change detection for a single config file.
//!
//! A `Detector` remembers the file's last-seen mtime and size. On every
//! `poll()` it compares the current stat to the stored snapshot and
//! returns one of:
//!
//!   - `.unchanged` — no-op.
//!   - `.changed` — mtime or size differs; snapshot updated.
//!   - `.removed` — the file disappeared; snapshot cleared.
//!   - `.appeared` — file exists now but didn't before; snapshot installed.
//!
//! No filesystem watchers, no threads. The harness polls at its own
//! cadence. This keeps the dependency surface small and the behaviour
//! portable.

const std = @import("std");
const Io = std.Io;

pub const Event = enum {
    unchanged,
    changed,
    removed,
    appeared,
};

pub const Snapshot = struct {
    mtime: Io.Timestamp,
    size: u64,

    pub fn eql(a: Snapshot, b: Snapshot) bool {
        return a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds;
    }
};

pub const Detector = struct {
    last: ?Snapshot = null,

    pub fn init() Detector {
        return .{};
    }

    pub const PollError = Io.Dir.StatFileError;

    pub fn poll(
        self: *Detector,
        dir: Io.Dir,
        io: Io,
        sub_path: []const u8,
    ) PollError!Event {
        const stat_result: ?Io.Dir.Stat = dir.statFile(io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };

        if (stat_result == null) {
            if (self.last == null) return .unchanged;
            self.last = null;
            return .removed;
        }

        const st = stat_result.?;
        const now = Snapshot{ .mtime = st.mtime, .size = st.size };

        if (self.last) |prev| {
            if (prev.eql(now)) return .unchanged;
            self.last = now;
            return .changed;
        }

        self.last = now;
        return .appeared;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const internal_writes = @import("internal_writes.zig");

test "poll: missing file is .unchanged when never seen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var d = Detector.init();
    const ev = try d.poll(tmp.dir, testing.io, "nope.txt");
    try testing.expectEqual(Event.unchanged, ev);
}

test "poll: first appearance reports .appeared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var d = Detector.init();
    try internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.json", "{}");
    const ev = try d.poll(tmp.dir, testing.io, "cfg.json");
    try testing.expectEqual(Event.appeared, ev);
}

test "poll: unchanged content reports .unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.json", "{}");
    var d = Detector.init();
    _ = try d.poll(tmp.dir, testing.io, "cfg.json");

    const ev = try d.poll(tmp.dir, testing.io, "cfg.json");
    try testing.expectEqual(Event.unchanged, ev);
}

test "poll: size change reports .changed even if mtime resolution is coarse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.json", "{}");
    var d = Detector.init();
    _ = try d.poll(tmp.dir, testing.io, "cfg.json");

    // Different size guarantees the snapshot compare fails regardless of
    // whether the filesystem bumped mtime.
    try internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.json", "{\"log_level\":\"debug\"}");
    const ev = try d.poll(tmp.dir, testing.io, "cfg.json");
    try testing.expectEqual(Event.changed, ev);
}

test "poll: deletion reports .removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.json", "{}");
    var d = Detector.init();
    _ = try d.poll(tmp.dir, testing.io, "cfg.json");

    try tmp.dir.deleteFile(testing.io, "cfg.json");
    const ev = try d.poll(tmp.dir, testing.io, "cfg.json");
    try testing.expectEqual(Event.removed, ev);
}
