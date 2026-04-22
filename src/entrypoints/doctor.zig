//! `doctor` entrypoint.
//!
//! Prints a short self-check so operators can tell, in one command,
//! that the runtime can see its configuration, the sandbox policy,
//! and the state directory. Each check writes a single line; the
//! overall outcome is the logical AND of every line's ok flag.
//!
//! This is intentionally shallow for this commit. Deeper probes
//! (sandbox backend sanity, pricing-table sanity, provider reach-
//! ability) land alongside the subsystems that need them.

const std = @import("std");
const sandbox = @import("../sandbox/root.zig");
const harness = @import("../harness/root.zig");
const version = @import("../version.zig");

pub const Options = struct {
    io: std.Io,
    /// Where sessions live. Caller passes the resolved dir; doctor
    /// does not touch the filesystem layout.
    state_dir: std.Io.Dir,
    /// Starting mode. Doctor reports the capability table for it.
    mode: harness.Mode = .run,
    /// Writer for operator-visible lines.
    output: *std.Io.Writer,
};

pub const Report = struct {
    ok: bool,
    checks_run: u32,
    checks_failed: u32,
};

pub fn doctor(opts: Options) !Report {
    var checks_run: u32 = 0;
    var checks_failed: u32 = 0;

    try opts.output.print("tigerclaw {s}\n", .{version.string});
    try opts.output.writeAll("---\n");

    // Mode + capabilities: not a pass/fail check, but documents
    // what the session is allowed to do.
    checks_run += 1;
    const caps = harness.mode_policy.Capabilities.of(opts.mode);
    try opts.output.print(
        "mode: {s} (network={s}, clock={s}, fs_writes={s}, subprocess={s})\n",
        .{
            @tagName(opts.mode),
            yesno(caps.live_network),
            yesno(caps.wall_clock),
            yesno(caps.filesystem_writes),
            yesno(caps.subprocess_spawn),
        },
    );

    // Sandbox backend selection. Failing is not a doctor failure —
    // falling back to noop is a legal configuration — but we
    // surface it so an operator expecting firejail notices.
    checks_run += 1;
    var storage: sandbox.Storage = .{};
    const sb = sandbox.detect.open(&storage, .auto);
    try opts.output.print("sandbox: backend={s}, available={s}\n", .{ sb.name(), yesno(sb.isAvailable()) });

    // State directory probe. If we cannot touch the dir, the
    // harness will fail later with a less obvious error; catching
    // it here gives the operator a clear diagnostic.
    checks_run += 1;
    const probe_name = ".tigerclaw-doctor-probe";
    var probe_ok = true;
    opts.state_dir.access(opts.io, probe_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // expected, the probe does not exist
        else => {
            probe_ok = false;
            try opts.output.print("state_dir: error on probe: {any}\n", .{err});
        },
    };
    if (probe_ok) {
        try opts.output.writeAll("state_dir: reachable\n");
    } else {
        checks_failed += 1;
    }

    try opts.output.writeAll("---\n");
    if (checks_failed == 0) {
        try opts.output.writeAll("status: ok\n");
    } else {
        try opts.output.print("status: {d} check(s) failed\n", .{checks_failed});
    }

    return .{
        .ok = checks_failed == 0,
        .checks_run = checks_run,
        .checks_failed = checks_failed,
    };
}

fn yesno(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "doctor: clean environment yields an ok report" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const report = try doctor(.{
        .io = testing.io,
        .state_dir = tmp.dir,
        .mode = .run,
        .output = &out,
    });

    try testing.expect(report.ok);
    try testing.expectEqual(@as(u32, 0), report.checks_failed);

    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "mode: run") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sandbox: backend=noop") != null);
    try testing.expect(std.mem.indexOf(u8, text, "state_dir: reachable") != null);
    try testing.expect(std.mem.indexOf(u8, text, "status: ok") != null);
}

test "doctor: bench mode is documented as such" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    _ = try doctor(.{
        .io = testing.io,
        .state_dir = tmp.dir,
        .mode = .bench,
        .output = &out,
    });

    try testing.expect(std.mem.indexOf(u8, out.buffered(), "mode: bench (network=no") != null);
}
