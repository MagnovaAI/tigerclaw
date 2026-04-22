//! Session-mode policy.
//!
//! The runtime operates in one of four mutually exclusive modes:
//!
//!   * `run`    — normal interactive/automated use. Live providers,
//!                real network I/O, full tool surface.
//!   * `bench`  — benchmarking. Deterministic inputs, fixed clocks,
//!                replay-backed providers only (see `bench_guards`).
//!   * `replay` — replay a recorded trace / VCR cassette. No live
//!                network. No wall-clock sampling.
//!   * `eval`   — evaluation harness. Same determinism rules as
//!                `bench` but with judge/witness assertions layered on.
//!
//! The mode is **pinned for the lifetime of a session**. Switching
//! modes mid-session is a bug (it would let a live `run` session
//! pretend its results are replay-deterministic). `Policy` enforces
//! this by refusing any transition once a mode is active, surfacing
//! `error.ModePinned` instead of silently accepting the change.
//!
//! The canonical `Mode` enum lives in `settings.schema.Mode` — we
//! re-export it from here so harness callers do not need to reach
//! into the settings subsystem.

const std = @import("std");
const schema = @import("../settings/schema.zig");

pub const Mode = schema.Mode;

/// Errors surfaced by `Policy` operations.
pub const Error = error{
    /// A transition was attempted on an already-pinned session.
    ModePinned,
};

/// Which subsystems are legal to exercise in a given mode. This is
/// the truth table the runtime consults before doing potentially
/// non-deterministic work (live network, wall-clock reads, etc.).
pub const Capabilities = struct {
    live_network: bool,
    wall_clock: bool,
    filesystem_writes: bool,
    subprocess_spawn: bool,

    pub fn of(mode: Mode) Capabilities {
        return switch (mode) {
            .run => .{
                .live_network = true,
                .wall_clock = true,
                .filesystem_writes = true,
                .subprocess_spawn = true,
            },
            .bench => .{
                // Bench requires reproducible timing; no live network
                // because response latency would pollute measurements.
                .live_network = false,
                .wall_clock = false,
                .filesystem_writes = true,
                .subprocess_spawn = false,
            },
            .replay => .{
                // Replay is pure: it consumes recorded traces only.
                .live_network = false,
                .wall_clock = false,
                .filesystem_writes = false,
                .subprocess_spawn = false,
            },
            .eval => .{
                // Eval is bench + assertions; same hard limits.
                .live_network = false,
                .wall_clock = false,
                .filesystem_writes = true,
                .subprocess_spawn = false,
            },
        };
    }
};

/// Session-scoped mode holder. One instance per session; the
/// `Harness` constructs this and stores it so every later `require`
/// check sees the same pinned mode.
pub const Policy = struct {
    mode: Mode,

    pub fn init(mode: Mode) Policy {
        return .{ .mode = mode };
    }

    pub fn current(self: *const Policy) Mode {
        return self.mode;
    }

    pub fn capabilities(self: *const Policy) Capabilities {
        return Capabilities.of(self.mode);
    }

    /// Transition the mode. Always returns `error.ModePinned` unless
    /// the target equals the current mode (which is a no-op). This
    /// is deliberately the entire transition API — the runtime
    /// choosing a mode is a startup concern, not a mid-session one.
    pub fn transition(self: *Policy, target: Mode) Error!void {
        if (self.mode == target) return;
        return Error.ModePinned;
    }

    /// Assert that the running mode is one of the allowed set. Used
    /// at the entry of bench/replay/eval code paths to prove the
    /// caller is not in `run`.
    pub fn require(self: *const Policy, allowed: []const Mode) !void {
        for (allowed) |m| if (self.mode == m) return;
        return error.ModeNotAllowed;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Policy: current reports the pinned mode" {
    const p = Policy.init(.run);
    try testing.expectEqual(Mode.run, p.current());
}

test "Policy: transition to the same mode is a no-op" {
    var p = Policy.init(.bench);
    try p.transition(.bench);
    try testing.expectEqual(Mode.bench, p.current());
}

test "Policy: transition to a different mode is rejected" {
    var p = Policy.init(.run);
    try testing.expectError(Error.ModePinned, p.transition(.bench));
    try testing.expectEqual(Mode.run, p.current());
}

test "Policy: run mode grants every capability" {
    const caps = Policy.init(.run).capabilities();
    try testing.expect(caps.live_network);
    try testing.expect(caps.wall_clock);
    try testing.expect(caps.filesystem_writes);
    try testing.expect(caps.subprocess_spawn);
}

test "Policy: bench and eval forbid live network and wall clock" {
    for ([_]Mode{ .bench, .eval }) |m| {
        const caps = Policy.init(m).capabilities();
        try testing.expect(!caps.live_network);
        try testing.expect(!caps.wall_clock);
    }
}

test "Policy: replay forbids every side effect" {
    const caps = Policy.init(.replay).capabilities();
    try testing.expect(!caps.live_network);
    try testing.expect(!caps.wall_clock);
    try testing.expect(!caps.filesystem_writes);
    try testing.expect(!caps.subprocess_spawn);
}

test "Policy: require accepts the current mode and rejects others" {
    const p = Policy.init(.bench);
    try p.require(&.{ .bench, .eval });
    try testing.expectError(error.ModeNotAllowed, p.require(&.{ .run, .replay }));
}
