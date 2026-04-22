//! Prompt-cache breakpoint planning.
//!
//! Anthropic's prompt caching (and OpenAI's equivalent) charges
//! full price for the first prefix of a request and a reduced
//! rate for any bytes the provider can match against a recent
//! cache entry. The entries are keyed by the whole prefix up to
//! a declared "cache breakpoint" marker. Picking the right
//! breakpoints is worth a lot of money on long system prompts:
//! a stable system prompt plus a small volatile tail hits the
//! cache on every call after the first.
//!
//! This module does not call any provider. It plans the
//! breakpoints: given the current `Input`, it emits a list of
//! `Breakpoint` positions the provider adapter can translate into
//! its own wire format.
//!
//! Strategy for this commit:
//!
//!   * If a system prompt is present and large enough to be worth
//!     caching (`min_bytes`), place a breakpoint at its end.
//!   * Optionally place a breakpoint before the last N messages
//!     so the "stable past" and "recent tail" split naturally.
//!     Default N is 0 — history caching is opt-in because very
//!     dynamic workflows waste entries that way.
//!
//! Providers typically have a hard cap of four breakpoints; we
//! cap at that to keep this safe to hand to any backend.

const std = @import("std");
const types = @import("types");

/// Where a breakpoint should be emitted, expressed in terms the
/// provider adapter can act on.
pub const Position = union(enum) {
    /// Emit the breakpoint on the system block.
    system_end,
    /// Emit on the N-th message (0-indexed).
    message_end: usize,
};

pub const Breakpoint = struct {
    position: Position,
};

pub const Config = struct {
    /// Minimum system-prompt byte length to bother caching. Very
    /// short prompts (a sentence) are cheaper to resend than to
    /// manage as a cache entry.
    min_system_bytes: usize = 1024,
    /// How many trailing messages to leave *outside* the cached
    /// prefix. `0` disables history caching.
    history_tail_uncached: usize = 0,
    /// Provider-side cap on breakpoints. We never emit more than
    /// this regardless of how many positions would qualify.
    max_breakpoints: usize = 4,
};

pub const PlanResult = struct {
    breakpoints: [4]Breakpoint = undefined,
    len: usize = 0,

    pub fn slice(self: *const PlanResult) []const Breakpoint {
        return self.breakpoints[0..self.len];
    }
};

/// Produce up to `cfg.max_breakpoints` breakpoints. Returns a
/// small stack-allocated `PlanResult` (no heap) — the number of
/// breakpoints is provider-capped at 4 in practice.
pub fn plan(
    system: ?[]const u8,
    history: []const types.Message,
    cfg: Config,
) PlanResult {
    var out = PlanResult{};
    const cap = @min(cfg.max_breakpoints, out.breakpoints.len);

    if (system) |s| {
        if (s.len >= cfg.min_system_bytes and out.len < cap) {
            out.breakpoints[out.len] = .{ .position = .system_end };
            out.len += 1;
        }
    }

    if (cfg.history_tail_uncached != 0 and out.len < cap) {
        // Index of the message that is the *last cached* one. We
        // want the breakpoint to fall right after it, i.e. we
        // cache messages `0 .. history.len - tail` and leave the
        // tail `[history.len - tail .. history.len)` uncached.
        if (history.len > cfg.history_tail_uncached) {
            const idx = history.len - cfg.history_tail_uncached - 1;
            out.breakpoints[out.len] = .{ .position = .{ .message_end = idx } };
            out.len += 1;
        }
    }

    return out;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "plan: no system + empty history emits nothing" {
    const r = plan(null, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "plan: short system prompt is not cached" {
    const short_system = "you are helpful";
    const r = plan(short_system, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "plan: long system prompt emits system_end" {
    const long = "x" ** 4096;
    const r = plan(long, &.{}, .{});
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(Position.system_end, r.breakpoints[0].position);
}

test "plan: min_system_bytes overridable" {
    const short = "hello, world";
    const r = plan(short, &.{}, .{ .min_system_bytes = 8 });
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "plan: history tail caching falls right after the last cached message" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "1" },
        .{ .role = .assistant, .content = "2" },
        .{ .role = .user, .content = "3" },
        .{ .role = .assistant, .content = "4" },
        .{ .role = .user, .content = "5" },
    };
    const r = plan(null, &msgs, .{ .history_tail_uncached = 2 });
    try testing.expectEqual(@as(usize, 1), r.len);
    // Cached prefix = messages 0..3; breakpoint lands on msg 2.
    try testing.expectEqual(@as(usize, 2), r.breakpoints[0].position.message_end);
}

test "plan: history shorter than tail is left entirely uncached" {
    const msgs = [_]types.Message{.{ .role = .user, .content = "only" }};
    const r = plan(null, &msgs, .{ .history_tail_uncached = 5 });
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "plan: respects max_breakpoints cap" {
    const long = "x" ** 4096;
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "a" },
        .{ .role = .user, .content = "b" },
        .{ .role = .user, .content = "c" },
    };
    const r = plan(long, &msgs, .{ .history_tail_uncached = 1, .max_breakpoints = 1 });
    // Only system_end fits; message_end is dropped.
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(Position.system_end, r.breakpoints[0].position);
}
