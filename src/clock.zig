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
