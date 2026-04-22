//! Error classification for the routing fallback decision.
//!
//! `isRetryable` answers: should the router try the next provider in
//! the chain, or surface this error to the caller immediately? The
//! predicate is deliberately narrow — transient I/O, rate-limiting,
//! and upstream "unavailable" signals advance; validation errors,
//! budget exhaustion, and mode-forbidden operations do not.

pub fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ReadFailed,
        error.WriteFailed,
        error.BrokenPipe,
        error.TemporaryNameServerFailure,
        error.RateLimited,
        error.Unavailable,
        error.TimedOut,
        error.MockExhausted,
        => true,
        else => false,
    };
}

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "isRetryable: transient I/O errors advance the chain" {
    try testing.expect(isRetryable(error.ConnectionResetByPeer));
    try testing.expect(isRetryable(error.ConnectionTimedOut));
    try testing.expect(isRetryable(error.ReadFailed));
    try testing.expect(isRetryable(error.BrokenPipe));
    try testing.expect(isRetryable(error.TimedOut));
}

test "isRetryable: rate limit and unavailable advance" {
    try testing.expect(isRetryable(error.RateLimited));
    try testing.expect(isRetryable(error.Unavailable));
}

test "isRetryable: validation-style errors do not advance" {
    try testing.expect(!isRetryable(error.InvalidArgument));
    try testing.expect(!isRetryable(error.OutOfMemory));
    try testing.expect(!isRetryable(error.PermissionDenied));
}

test "isRetryable: MockExhausted advances (treated as unavailable)" {
    try testing.expect(isRetryable(error.MockExhausted));
}
