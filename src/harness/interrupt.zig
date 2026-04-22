//! Cooperative interrupt signal.
//!
//! Long-running agent work (multi-turn loops, streaming provider
//! calls, tool execution) must be cancellable without tearing the
//! process down. The `Interrupt` is the canonical flag the harness
//! exposes for that purpose.
//!
//! Contract:
//!   * `request()` sets the flag. Safe to call from any thread, any
//!     number of times — idempotent.
//!   * `isRequested()` is a lock-free read. Consumers poll it at the
//!     safe points they choose (between turns, between tool calls,
//!     between SSE chunks). There is no preemption; this is purely
//!     cooperative.
//!   * `clear()` resets the flag. Callers clear after acknowledging
//!     the interrupt (typically right before the next turn starts)
//!     so a stale signal from a previous cancellation does not
//!     cancel fresh work.
//!
//! Patterned on the v1 runtime's `Agent.requestInterrupt` atomic: a
//! single `std.atomic.Value(bool)` is enough, and importantly it
//! needs no allocator so it can live inline on any struct.

const std = @import("std");

pub const Interrupt = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn request(self: *Interrupt) void {
        self.flag.store(true, .release);
    }

    pub fn clear(self: *Interrupt) void {
        self.flag.store(false, .release);
    }

    pub fn isRequested(self: *const Interrupt) bool {
        return self.flag.load(.acquire);
    }

    /// Convenience: returns `error.Interrupted` when the flag is set.
    /// Useful in `try`-chains at poll points so the control-flow stays
    /// linear.
    pub fn check(self: *const Interrupt) !void {
        if (self.isRequested()) return error.Interrupted;
    }
};

pub const Error = error{Interrupted};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Interrupt: default state is not requested" {
    const i = Interrupt{};
    try testing.expect(!i.isRequested());
}

test "Interrupt: request then clear toggles the flag" {
    var i = Interrupt{};
    i.request();
    try testing.expect(i.isRequested());
    i.clear();
    try testing.expect(!i.isRequested());
}

test "Interrupt: request is idempotent" {
    var i = Interrupt{};
    i.request();
    i.request();
    i.request();
    try testing.expect(i.isRequested());
}

test "Interrupt: check returns Interrupted when set" {
    var i = Interrupt{};
    try i.check();
    i.request();
    try testing.expectError(error.Interrupted, i.check());
}

test "Interrupt: cross-thread signal is observed" {
    var i = Interrupt{};

    const Worker = struct {
        fn go(ptr: *Interrupt) void {
            ptr.request();
        }
    };

    var th = try std.Thread.spawn(.{}, Worker.go, .{&i});
    th.join();
    try testing.expect(i.isRequested());
}
