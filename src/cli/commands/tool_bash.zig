//! Real shell execution for the live runner.
//!
//! Spawns `/bin/sh -c <command>` via `std.process.run`, which on
//! Zig 0.16 already pipes both stdout and stderr concurrently and
//! supports a wall-clock `timeout`. The std runner takes care of
//! pipe-full deadlocks and child cleanup; we just enforce caps and
//! surface a denylist for the well-known destructive patterns.

const std = @import("std");
const builtin = @import("builtin");

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
    /// Optional sink invoked with each freshly-read slice of the
    /// child's stdout/stderr, fired live during the read loop. The
    /// runner uses this to surface long-running shell output (e.g.
    /// `git push`, `cargo build`) to the TUI as it arrives instead
    /// of waiting for the whole command to finish. Each invocation
    /// borrows the bytes for the duration of the call; sinks that
    /// need to keep the data must dupe.
    progress_sink: ?ProgressSink = null,
    progress_ctx: ?*anyopaque = null,
    /// Shared turn cancel flag. When set, the shell and its children
    /// are terminated and the result is marked interrupted.
    cancel_token: ?*const std.atomic.Value(bool) = null,
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

    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", options.command },
        .cwd = .{ .path = options.cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // Put POSIX shells in their own process group. A cancelled
        // `find ... -exec ...` otherwise leaves the grandchild alive
        // after the shell dies, keeping the UI stuck in "stopping".
        .pgid = if (supportsProcessGroups()) 0 else null,
    }) catch |err| switch (err) {
        else => return error.SpawnFailed,
    };
    var child_alive = true;
    defer if (child_alive) child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const poll_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(100),
        .clock = .awake,
    } };

    // Track how many bytes of each stream have already been
    // forwarded through `progress_sink` so we never double-emit on
    // the next loop iteration. `MultiReader.reader(idx).end` grows
    // monotonically as `fill` accumulates bytes; the slice
    // `[emitted..end]` is the freshly-arrived chunk.
    var emitted_stdout: usize = 0;
    var emitted_stderr: usize = 0;

    while (true) {
        if (options.cancel_token) |token| {
            if (token.load(.acquire)) {
                terminateChildTree(&child, io);
                child_alive = false;
                return interruptedResult(allocator, io, start_ts, "bash: command cancelled by user");
            }
        }

        if (elapsedMs(io, start_ts) >= timeout_ms) {
            terminateChildTree(&child, io);
            child_alive = false;
            const stderr = try std.fmt.allocPrint(
                allocator,
                "bash: command timed out after {d} ms",
                .{timeout_ms},
            );
            return interruptedResultOwned(allocator, io, start_ts, stderr);
        }

        const fill_result = multi_reader.fill(64, poll_timeout);

        // Drain freshly-arrived bytes through the live progress
        // sink BEFORE handling fill's terminal states. On EOF we
        // still want the tail of the buffer to surface as a chunk.
        if (options.progress_sink) |sink| {
            const stdout_r = multi_reader.reader(0);
            if (stdout_r.end > emitted_stdout) {
                sink(options.progress_ctx, .stdout_chunk, stdout_r.buffer[emitted_stdout..stdout_r.end]);
                emitted_stdout = stdout_r.end;
            }
            const stderr_r = multi_reader.reader(1);
            if (stderr_r.end > emitted_stderr) {
                sink(options.progress_ctx, .stderr_chunk, stderr_r.buffer[emitted_stderr..stderr_r.end]);
                emitted_stderr = stderr_r.end;
            }
        }

        fill_result catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => continue,
            else => return error.SpawnFailed,
        };
        // Fill returned without error before either stream EOF'd —
        // keep looping to read more.
    }

    multi_reader.checkAnyError() catch return error.SpawnFailed;
    const term = child.wait(io) catch return error.SpawnFailed;
    child_alive = false;

    const stdout_owned = try multi_reader.toOwnedSlice(0);
    const stderr_owned = multi_reader.toOwnedSlice(1) catch |err| {
        allocator.free(stdout_owned);
        return err;
    };

    const result: std.process.RunResult = .{
        .term = term,
        .stdout = stdout_owned,
        .stderr = stderr_owned,
    };

    // result owns stdout/stderr — we may need to trim or replace, so
    // be careful about ownership.
    return finishResult(allocator, io, start_ts, result);
}

fn finishResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,
    result: std.process.RunResult,
) BashError!BashResult {
    const owned = result;
    // Progress is streamed live during the read loop; nothing to
    // emit here.

    const stdout_trimmed = trimWithMarker(allocator, owned.stdout, "stdout") catch |e| {
        allocator.free(owned.stdout);
        allocator.free(owned.stderr);
        return e;
    };
    // stdout_trimmed may either be result.stdout (handed off) or a
    // newly-allocated slice. Free original only when replaced.
    if (stdout_trimmed.ptr != owned.stdout.ptr) allocator.free(owned.stdout);

    const stderr_trimmed = trimWithMarker(allocator, owned.stderr, "stderr") catch |e| {
        allocator.free(stdout_trimmed);
        allocator.free(owned.stderr);
        return e;
    };
    if (stderr_trimmed.ptr != owned.stderr.ptr) allocator.free(owned.stderr);

    return .{
        .stdout = stdout_trimmed,
        .stderr = stderr_trimmed,
        .exit_code = switch (owned.term) {
            .exited => |c| @intCast(c),
            .signal => -1,
            .stopped => -1,
            .unknown => -1,
        },
        .interrupted = switch (owned.term) {
            .exited => false,
            else => true,
        },
        .duration_ms = elapsedMs(io, start_ts),
    };
}

fn supportsProcessGroups() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .ios, .tvos, .visionos, .watchos => false,
        else => true,
    };
}

fn terminateChildTree(child: *std.process.Child, io: std.Io) void {
    if (supportsProcessGroups()) {
        if (child.id) |pid| {
            if (pid > 0) {
                while (true) switch (std.posix.errno(std.posix.system.kill(-pid, .TERM))) {
                    .SUCCESS, .SRCH => break,
                    .INTR => continue,
                    else => break,
                };
            }
        }
    }
    child.kill(io);
}

fn interruptedResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,
    stderr_text: []const u8,
) std.mem.Allocator.Error!BashResult {
    return interruptedResultOwned(
        allocator,
        io,
        start_ts,
        try allocator.dupe(u8, stderr_text),
    );
}

fn interruptedResultOwned(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,
    stderr: []u8,
) std.mem.Allocator.Error!BashResult {
    errdefer allocator.free(stderr);
    const stdout = try allocator.alloc(u8, 0);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = -1,
        .interrupted = true,
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

test "interruptedResultOwned: marks cancelled shell results" {
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const stderr = try testing.allocator.dupe(u8, "bash: command cancelled by user");
    const result = try interruptedResultOwned(testing.allocator, std.testing.io, start, stderr);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, -1), result.exit_code);
    try testing.expect(result.interrupted);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("bash: command cancelled by user", result.stderr);
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
