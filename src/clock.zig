//! Injectable clock.
//!
//! Every module that needs time takes a `Clock` by value and calls
//! `clock.nowNs()`. This keeps tests deterministic — production wires a
//! `CallbackClock` over the runtime's time source; tests wire a
//! `FixedClock` or `ManualClock`.

const std = @import("std");

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_ns: *const fn (ptr: *anyopaque) i128,
    };

    pub fn nowNs(self: Clock) i128 {
        return self.vtable.now_ns(self.ptr);
    }
};

/// Wraps a caller-supplied `now_ns` function pointer. The runtime wires the
/// real wall-clock source through `Io` once the I/O subsystem lands; until
/// then, the entry point can pass a closure over whatever time source it
/// has access to.
pub const CallbackClock = struct {
    now_fn: *const fn () i128,

    pub fn clock(self: *CallbackClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn nowNs(ptr: *anyopaque) i128 {
        const self: *CallbackClock = @ptrCast(@alignCast(ptr));
        return self.now_fn();
    }

    const vtable = Clock.VTable{ .now_ns = nowNs };
};

/// Returns the same timestamp every call.
pub const FixedClock = struct {
    value_ns: i128,

    pub fn clock(self: *FixedClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn nowNs(ptr: *anyopaque) i128 {
        const self: *FixedClock = @ptrCast(@alignCast(ptr));
        return self.value_ns;
    }

    const vtable = Clock.VTable{ .now_ns = nowNs };
};

/// Caller advances the clock explicitly.
pub const ManualClock = struct {
    value_ns: i128 = 0,

    pub fn clock(self: *ManualClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn advance(self: *ManualClock, delta_ns: i128) void {
        self.value_ns += delta_ns;
    }

    fn nowNs(ptr: *anyopaque) i128 {
        const self: *ManualClock = @ptrCast(@alignCast(ptr));
        return self.value_ns;
    }

    const vtable = Clock.VTable{ .now_ns = nowNs };
};

/// Wall-clock backed by clock_gettime(CLOCK_REALTIME). Use for
/// production; reads the OS clock each call. Non-deterministic so
/// don't wire into unit tests — use FixedClock or ManualClock.
pub const SystemClock = struct {
    pub fn clock(self: *SystemClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn nowNs(ptr: *anyopaque) i128 {
        _ = ptr;
        var ts: std.c.timespec = undefined;
        const rc = std.c.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0; // clock_gettime is documented infallible on modern OSes
        const sec_ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s;
        const nsec: i128 = @intCast(ts.nsec);
        return sec_ns + nsec;
    }

    const vtable = Clock.VTable{ .now_ns = nowNs };
};

// --- contract -------------------------------------------------------------

/// Shared contract: every Clock implementation must satisfy these
/// invariants. Call from contract tests of specific clock plugs.
pub fn runContract(c: Clock) !void {
    // Stability: calling twice in a row produces monotonically
    // non-decreasing output. Even FixedClock passes (returns the same
    // value each call).
    const t1 = c.nowNs();
    const t2 = c.nowNs();
    if (t2 < t1) return error.TestExpectedNonDecreasingClock;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "FixedClock returns its fixed value" {
    var fc = FixedClock{ .value_ns = 42 };
    const c = fc.clock();
    try testing.expectEqual(@as(i128, 42), c.nowNs());
    try testing.expectEqual(@as(i128, 42), c.nowNs());
}

test "ManualClock advances when told" {
    var mc = ManualClock{};
    const c = mc.clock();
    try testing.expectEqual(@as(i128, 0), c.nowNs());
    mc.advance(1_000);
    try testing.expectEqual(@as(i128, 1_000), c.nowNs());
    mc.advance(500);
    try testing.expectEqual(@as(i128, 1_500), c.nowNs());
}

test "CallbackClock dispatches to the supplied function" {
    const S = struct {
        fn sevens() i128 {
            return 7;
        }
    };
    var cb = CallbackClock{ .now_fn = &S.sevens };
    const c = cb.clock();
    try testing.expectEqual(@as(i128, 7), c.nowNs());
}

test "SystemClock returns a plausible wall-clock timestamp" {
    var sc = SystemClock{};
    const c = sc.clock();
    const t = c.nowNs();
    // >= 2020-01-01 in ns. Anything older means we're reading garbage.
    const year_2020_ns: i128 = 1577836800 * std.time.ns_per_s;
    try testing.expect(t >= year_2020_ns);
}

test "contract: FixedClock passes runContract" {
    var fc = FixedClock{ .value_ns = 1000 };
    try runContract(fc.clock());
}

test "contract: ManualClock passes runContract" {
    var mc = ManualClock{};
    try runContract(mc.clock());
}

test "contract: SystemClock passes runContract" {
    var sc = SystemClock{};
    try runContract(sc.clock());
}
