//! Real shell execution for the live runner.
//!
//! Spawns `/bin/sh -c <command>` via `std.process.run`, which on
//! Zig 0.16 already pipes both stdout and stderr concurrently and
//! supports a wall-clock `timeout`. The std runner takes care of
//! pipe-full deadlocks and child cleanup; we just enforce caps and
//! surface a denylist for the well-known destructive patterns.

const std = @import("std");

pub const BashError = error{
    DeniedCommand,
    SpawnFailed,
    InvalidArgs,
} || std.mem.Allocator.Error;

pub const ProgressKind = enum { stdout_chunk, stderr_chunk };
pub const ProgressSink = *const fn (
    ctx: ?*anyopaque,
    kind: ProgressKind,
    bytes: []const u8,
) void;

pub const BashOptions = struct {
    /// Shell command, passed verbatim to `/bin/sh -c`.
    command: []const u8,
    /// Working directory. Workspace root in tigerclaw's case.
    cwd: []const u8,
    /// Wall-clock timeout in ms. Clamped at MAX_TIMEOUT_MS.
    timeout_ms: u64 = 120_000,
    /// Optional sink invoked on the captured stdout/stderr. Today
    /// the runner uses `std.process.run` which buffers both streams
    /// and surfaces them only on completion -- so we fire the sink
    /// once with the full buffer at the end of the call rather than
    /// chunk-by-chunk. Honest semantics: consumers see the data, but
    /// they don't see it incrementally. A future refactor that
    /// drives `std.process.spawn + multi_reader.fill` directly can
    /// keep the same sink contract and gain real streaming for free.
    progress_sink: ?ProgressSink = null,
    progress_ctx: ?*anyopaque = null,
};

pub const BashResult = struct {
    /// Owned. Capped at STREAM_CAP_BYTES; truncation marker appended on overflow.
    stdout: []u8,
    /// Owned. Same cap as stdout.
    stderr: []u8,
    /// Exit code (0..255) for normal exit; -1 for signal / interrupted.
    exit_code: i32,
    interrupted: bool,
    duration_ms: u64,

    pub fn deinit(self: BashResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Per-stream cap surfaced to the model. The std runner buffers the
/// full stream during the wait; we trim afterwards so the truncation
/// marker can honestly say more was available.
pub const STREAM_CAP_BYTES: usize = 32 * 1024;

/// Hard ceiling on caller-requested timeout. Anything higher gets clamped.
pub const MAX_TIMEOUT_MS: u64 = 600_000;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: BashOptions,
) BashError!BashResult {
    if (isDenied(options.command)) return error.DeniedCommand;

    const timeout_ms = @min(options.timeout_ms, MAX_TIMEOUT_MS);

    const start_ts = std.Io.Clock.Timestamp.now(io, .awake);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", options.command },
        .cwd = .{ .path = options.cwd },
        // Stream caps include headroom for the truncation marker. The
        // runner returns StreamTooLong if either limit is exceeded; we
        // re-run unbounded in that case so we still capture *something*.
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        } },
    }) catch |err| switch (err) {
        error.Timeout => {
            const elapsed = elapsedMs(io, start_ts);
            // The std runner kills the child on Timeout via defer;
            // there's no captured stdout/stderr to surface. Synthesise
            // an explanatory pair instead.
            const stdout = try allocator.alloc(u8, 0);
            errdefer allocator.free(stdout);
            const stderr = try std.fmt.allocPrint(
                allocator,
                "bash: command timed out after {d} ms",
                .{timeout_ms},
            );
            return .{
                .stdout = stdout,
                .stderr = stderr,
                .exit_code = -1,
                .interrupted = true,
                .duration_ms = elapsed,
            };
        },
        else => return error.SpawnFailed,
    };
    // result owns stdout/stderr — we may need to trim or replace, so
    // be careful about ownership.

    // Fire the progress sink with the full captured buffers before
    // we trim. Listeners that pipe to a TUI widget see the same data
    // they would get through a streamed spawn -- just all at once.
    if (options.progress_sink) |sink| {
        if (result.stdout.len > 0) sink(options.progress_ctx, .stdout_chunk, result.stdout);
        if (result.stderr.len > 0) sink(options.progress_ctx, .stderr_chunk, result.stderr);
    }

    const stdout_trimmed = try trimWithMarker(allocator, result.stdout, "stdout");
    // stdout_trimmed may either be result.stdout (handed off) or a
    // newly-allocated slice. Free original only when replaced.
    if (stdout_trimmed.ptr != result.stdout.ptr) allocator.free(result.stdout);

    const stderr_trimmed = trimWithMarker(allocator, result.stderr, "stderr") catch |e| {
        allocator.free(stdout_trimmed);
        return e;
    };
    if (stderr_trimmed.ptr != result.stderr.ptr) allocator.free(result.stderr);

    return .{
        .stdout = stdout_trimmed,
        .stderr = stderr_trimmed,
        .exit_code = switch (result.term) {
            .exited => |c| @intCast(c),
            .signal => -1,
            .stopped => -1,
            .unknown => -1,
        },
        .interrupted = switch (result.term) {
            .exited => false,
            else => true,
        },
        .duration_ms = elapsedMs(io, start_ts),
    };
}

fn elapsedMs(io: std.Io, start: std.Io.Clock.Timestamp) u64 {
    const elapsed = start.untilNow(io);
    const ns = elapsed.raw.nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

/// Return the input slice unchanged when it fits, or a freshly
/// allocated truncated slice with a visible marker when it doesn't.
fn trimWithMarker(
    allocator: std.mem.Allocator,
    raw: []u8,
    label: []const u8,
) ![]u8 {
    if (raw.len <= STREAM_CAP_BYTES) return raw;
    const marker = try std.fmt.allocPrint(
        allocator,
        "\n[{s} truncated, total {d} bytes — re-issue with a more specific command if you need more]",
        .{ label, raw.len },
    );
    defer allocator.free(marker);
    var out = try allocator.alloc(u8, STREAM_CAP_BYTES + marker.len);
    @memcpy(out[0..STREAM_CAP_BYTES], raw[0..STREAM_CAP_BYTES]);
    @memcpy(out[STREAM_CAP_BYTES..], marker);
    return out;
}

// ---------------------------------------------------------------------------
// Denylist — substring match, after trimming. Case-sensitive.

/// Public for testing; the runner only ever asks `run` to evaluate.
pub fn isDenied(command: []const u8) bool {
    const cmd = std.mem.trim(u8, command, " \t\n\r");

    // sudo with word boundary so `sudoers`, `pseudo`, `--sudo` slip past.
    if (containsWordBounded(cmd, "sudo")) return true;

    // bare-root rm: `rm -rf /` not followed by a path-extending char.
    if (matchesBareRootRm(cmd)) return true;

    // fork bomb (with or without spaces).
    if (std.mem.indexOf(u8, cmd, ":(){:|:&};:") != null) return true;
    if (std.mem.indexOf(u8, cmd, ":() { :|: & };:") != null) return true;

    // disk wipe via dd onto a raw block device.
    if (std.mem.indexOf(u8, cmd, "dd if=/dev/zero of=/dev/sd") != null) return true;
    if (std.mem.indexOf(u8, cmd, "dd if=/dev/zero of=/dev/disk") != null) return true;
    if (std.mem.indexOf(u8, cmd, "dd if=/dev/zero of=/dev/nvme") != null) return true;

    // mkfs.* near command start.
    if (std.mem.startsWith(u8, cmd, "mkfs.")) return true;

    // device-write redirect.
    if (std.mem.indexOf(u8, cmd, "> /dev/sd") != null) return true;
    if (std.mem.indexOf(u8, cmd, "> /dev/disk") != null) return true;
    if (std.mem.indexOf(u8, cmd, "> /dev/nvme") != null) return true;

    return false;
}

fn matchesBareRootRm(cmd: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, cmd, i, "rm -rf /")) |pos| {
        const after = pos + "rm -rf /".len;
        if (after >= cmd.len) return true;
        const c = cmd[after];
        const is_extender = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!is_extender) return true;
        i = after;
    }
    return false;
}

fn containsWordBounded(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        const before_ok = pos == 0 or !isWordChar(haystack[pos - 1]);
        const end = pos + needle.len;
        const after_ok = end == haystack.len or !isWordChar(haystack[end]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "denylist: rejects sudo with word boundary" {
    try testing.expect(isDenied("sudo apt install foo"));
    try testing.expect(isDenied("ls && sudo rm bad"));
    try testing.expect(!isDenied("sudoers"));
    try testing.expect(!isDenied("pseudo"));
    try testing.expect(!isDenied("echo nosudo"));
}

test "denylist: bare-root rm matches but rm -rf /tmp/foo doesn't" {
    try testing.expect(isDenied("rm -rf /"));
    try testing.expect(isDenied("rm -rf / && echo done"));
    try testing.expect(!isDenied("rm -rf /tmp/foo"));
    try testing.expect(!isDenied("rm -rf /var/cache/build"));
}

test "denylist: fork bomb" {
    try testing.expect(isDenied(":(){:|:&};:"));
    try testing.expect(isDenied("echo a; :() { :|: & };:"));
}

test "denylist: dd disk wipe" {
    try testing.expect(isDenied("dd if=/dev/zero of=/dev/sda"));
    try testing.expect(isDenied("dd if=/dev/zero of=/dev/disk0"));
    try testing.expect(isDenied("dd if=/dev/zero of=/dev/nvme0n1"));
    try testing.expect(!isDenied("dd if=/dev/zero of=foo.bin"));
}

test "denylist: mkfs at start" {
    try testing.expect(isDenied("mkfs.ext4 /dev/sdb1"));
    try testing.expect(!isDenied("touch mkfs.log"));
}

test "denylist: device-write redirect" {
    try testing.expect(isDenied("echo bad > /dev/sda"));
    try testing.expect(!isDenied("echo ok > /dev/null"));
}

test "trimWithMarker: short input passes through" {
    const small = try testing.allocator.dupe(u8, "hi");
    defer testing.allocator.free(small);
    const out = try trimWithMarker(testing.allocator, small, "stdout");
    // returned slice shares memory with input — don't free.
    try testing.expectEqual(small.ptr, out.ptr);
    try testing.expectEqualStrings("hi", out);
}

test "ProgressSink type signature accepts a captured-counter callback" {
    const Counter = struct {
        count: usize = 0,
        fn cb(ctx: ?*anyopaque, _: ProgressKind, _: []const u8) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.count += 1;
        }
    };
    var counter: Counter = .{};
    const sink: ProgressSink = Counter.cb;
    sink(&counter, .stdout_chunk, "hi");
    sink(&counter, .stderr_chunk, "err");
    try testing.expectEqual(@as(usize, 2), counter.count);
}

test "trimWithMarker: oversize input gets capped + marker" {
    const big = try testing.allocator.alloc(u8, STREAM_CAP_BYTES + 100);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const out = try trimWithMarker(testing.allocator, big, "stdout");
    defer testing.allocator.free(out);
    try testing.expect(out.len > STREAM_CAP_BYTES);
    try testing.expect(std.mem.indexOf(u8, out, "truncated") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stdout") != null);
}
