//! Classifies a provider error into a policy class.
//!
//! `Class` is what retry / circuit-breaker branch on. It overlaps with
//! `routing/fallback.zig` on purpose: routing asks "should I advance the
//! fallback chain?" and reliability asks "should I retry this exact
//! provider?". Keeping them separate lets us tune one without breaking
//! the other.

pub const Class = enum {
    /// Transient; retry is safe.
    retryable,
    /// Rate-limited; retry is safe but usually wants a larger backoff.
    rate_limited,
    /// Non-recoverable; do not retry.
    terminal,
};

pub fn classify(err: anyerror) Class {
    return switch (err) {
        error.RateLimited => .rate_limited,

        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.BrokenPipe,
        error.TemporaryNameServerFailure,
        error.Unavailable,
        error.TimedOut,
        => .retryable,

        else => .terminal,
    };
}

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "classify: rate_limited" {
    try testing.expectEqual(Class.rate_limited, classify(error.RateLimited));
}

test "classify: retryable transient errors" {
    try testing.expectEqual(Class.retryable, classify(error.ConnectionResetByPeer));
    try testing.expectEqual(Class.retryable, classify(error.ReadFailed));
    try testing.expectEqual(Class.retryable, classify(error.TimedOut));
    try testing.expectEqual(Class.retryable, classify(error.Unavailable));
}

test "classify: everything else is terminal" {
    try testing.expectEqual(Class.terminal, classify(error.InvalidArgument));
    try testing.expectEqual(Class.terminal, classify(error.OutOfMemory));
    try testing.expectEqual(Class.terminal, classify(error.PermissionDenied));
}
