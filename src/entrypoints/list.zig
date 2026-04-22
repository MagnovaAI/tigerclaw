//! `list` entrypoint.
//!
//! Enumerates the sessions present in the state directory by
//! looking for `*.json` files. Each line is `<id>\t<turn_count>\t
//! <updated_at_ns>` so simple downstream tooling can `awk` or
//! `cut` for specific fields.
//!
//! This is a read-only operation — it only loads each session's
//! top-level JSON to pull turn_count and updated_at_ns. The full
//! `Session.resumeFromBytes` path rehydrates every message, which
//! is much more expensive and not what `list` needs.

const std = @import("std");
const harness = @import("../harness/root.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: std.Io.Dir,
    /// Caller writes consumed.
    output: *std.Io.Writer,
};

pub const Report = struct {
    /// Number of session files found and listed.
    count: usize,
};

pub fn list(opts: Options) !Report {
    // Walk the state dir for `*.json` files. We deliberately skip
    // `*.json.tmp` files, which are transient artefacts of the
    // `writeAtomic` helper — listing them would show sessions that
    // are mid-write.
    var it = try opts.state_dir.openDir(opts.io, ".", .{ .iterate = true });
    defer it.close(opts.io);

    var walker = it.iterate();
    var count: usize = 0;

    while (try walker.next(opts.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp.json")) continue;
        if (std.mem.endsWith(u8, entry.name, ".json.tmp")) continue;

        const bytes = opts.state_dir.readFileAlloc(
            opts.io,
            entry.name,
            opts.allocator,
            .limited(harness.harness.max_session_bytes),
        ) catch |err| {
            try opts.output.print("{s}\t?\t?\terror={any}\n", .{ entry.name, err });
            count += 1;
            continue;
        };
        defer opts.allocator.free(bytes);

        const parsed = harness.state.parse(opts.allocator, bytes) catch |err| {
            try opts.output.print("{s}\t?\t?\terror={any}\n", .{ entry.name, err });
            count += 1;
            continue;
        };
        defer parsed.deinit();

        try opts.output.print(
            "{s}\t{d}\t{d}\n",
            .{ parsed.value.id, parsed.value.turn_count, parsed.value.updated_at_ns },
        );
        count += 1;
    }

    return .{ .count = count };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("../clock.zig");

test "list: empty directory prints nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const r = try list(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .output = &out,
    });
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expectEqualStrings("", out.buffered());
}

test "list: reports every session with turn count and timestamp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Drop two sessions into the dir via the harness so format is
    // exactly what list() expects to read.
    var mc = clock_mod.ManualClock{ .value_ns = 10 };
    var h = harness.harness.Harness.init(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
    });
    var s1 = try h.startSession("alpha");
    defer s1.deinit();
    try s1.appendTurn("q", "a");
    try h.saveSession(&s1);

    mc.advance(5);
    var s2 = try h.startSession("beta");
    defer s2.deinit();
    try s2.appendTurn("u", "r");
    try s2.appendTurn("u2", "r2");
    try h.saveSession(&s2);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const r = try list(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .output = &out,
    });

    try testing.expectEqual(@as(usize, 2), r.count);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "alpha\t1\t") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta\t2\t") != null);
}
