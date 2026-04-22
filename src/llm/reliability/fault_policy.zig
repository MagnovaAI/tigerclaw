//! Policy-level fault simulation.
//!
//! Where `fault_injector.zig` fires transport-shaped errors, this module
//! simulates policy failures: a quota that a provider tightens, a tier
//! mid-session downgrade. Callers use it to answer "what *kind* of
//! refusal would I see if this policy trips right now?" without having
//! to ship a scripted error through the transport layer.
//!
//! Like every other reliability primitive, the clock is injected. The
//! caller advances the internal `now_ns` field so tests stay
//! deterministic.

const std = @import("std");

pub const Policy = struct {
    quota_requests: u32,
    quota_window_ns: i128,

    /// Internal state.
    count: u32 = 0,
    window_start_ns: i128 = 0,

    pub fn init(quota_requests: u32, quota_window_ns: i128) Policy {
        return .{ .quota_requests = quota_requests, .quota_window_ns = quota_window_ns };
    }

    pub const CheckError = error{
        QuotaExceeded,
    };

    /// Records a call at `now_ns`. Returns QuotaExceeded when the limit
    /// is exceeded in the current window.
    pub fn check(self: *Policy, now_ns: i128) CheckError!void {
        if (self.count == 0) self.window_start_ns = now_ns;
        if (now_ns - self.window_start_ns >= self.quota_window_ns) {
            self.count = 0;
            self.window_start_ns = now_ns;
        }
        self.count +|= 1;
        if (self.count > self.quota_requests) return error.QuotaExceeded;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Policy: allows up to quota_requests inside the window" {
    var p = Policy.init(3, std.time.ns_per_s);
    try p.check(0);
    try p.check(100);
    try p.check(200);
    try testing.expectError(error.QuotaExceeded, p.check(300));
}

test "Policy: resets counter across windows" {
    var p = Policy.init(2, std.time.ns_per_s);
    try p.check(0);
    try p.check(100);
    try testing.expectError(error.QuotaExceeded, p.check(200));

    // Past the window: counter resets.
    try p.check(std.time.ns_per_s + 1);
    try p.check(std.time.ns_per_s + 100);
    try testing.expectError(error.QuotaExceeded, p.check(std.time.ns_per_s + 200));
}
