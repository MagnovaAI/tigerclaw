//! Memory manager — holds the always-on built-in plus at most one
//! external provider.
//!
//! Why one external: composing two memory providers explodes the
//! per-turn surface (which one's prefetch wins? do we concat? do we
//! prefer most-recent?) and forces the runner to model conflict
//! resolution it has no business modelling. Hermes shipped with this
//! rule and never had to revisit it. We adopt it verbatim.
//!
//! The manager itself is not a `Provider`; the runner asks it for
//! the active providers in priority order (built-in first, external
//! second when present) and calls each in turn. Concatenation of
//! prefetch/system-prompt happens at the call site, not here.

const std = @import("std");
const provider_mod = @import("provider.zig");

pub const RegisterError = error{
    /// Caller tried to register a second external provider. Only the
    /// first one wins; subsequent registrations are rejected and the
    /// runner is expected to log the rejection.
    ExternalAlreadyRegistered,
    /// Caller tried to register a built-in when one is already set.
    /// Built-in is set once at construction; this guards mistakes.
    BuiltinAlreadyRegistered,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    builtin: provider_mod.Provider,
    external: ?provider_mod.Provider = null,

    /// Manager takes the built-in as a constructor arg because there
    /// is no legitimate state where one is absent — the rule says
    /// built-in is always present.
    pub fn init(
        allocator: std.mem.Allocator,
        builtin: provider_mod.Provider,
    ) Manager {
        std.debug.assert(builtin.kind == .builtin);
        return .{ .allocator = allocator, .builtin = builtin };
    }

    pub fn deinit(self: *Manager) void {
        if (self.external) |ext| ext.shutdown();
        self.builtin.shutdown();
        self.* = undefined;
    }

    /// Register an external provider. Returns `ExternalAlreadyRegistered`
    /// if one is already in place; the caller is expected to log a
    /// warning so operators see the misconfiguration. Built-in cannot
    /// be re-registered through this path.
    pub fn registerExternal(
        self: *Manager,
        external: provider_mod.Provider,
    ) RegisterError!void {
        switch (external.kind) {
            .external => {
                if (self.external != null) return RegisterError.ExternalAlreadyRegistered;
                self.external = external;
            },
            .builtin => return RegisterError.BuiltinAlreadyRegistered,
        }
    }

    /// Iterate active providers in priority order: built-in first,
    /// external second (if any). Caller-allocated buffer; returns the
    /// number written. Buffer of size 2 covers every legal state.
    pub fn active(self: *const Manager, buf: []provider_mod.Provider) usize {
        if (buf.len == 0) return 0;
        buf[0] = self.builtin;
        var n: usize = 1;
        if (self.external) |ext| {
            if (n < buf.len) {
                buf[n] = ext;
                n += 1;
            }
        }
        return n;
    }

    /// Convenience: total count of active providers (1 or 2).
    pub fn count(self: *const Manager) usize {
        return if (self.external == null) 1 else 2;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Stub = struct {
    shutdown_calls: u32 = 0,

    fn provider(self: *Stub, kind: provider_mod.Kind, name: []const u8) provider_mod.Provider {
        return .{ .ptr = self, .vtable = &vt, .kind = kind, .name = name };
    }

    fn initFn(_: *anyopaque) provider_mod.MemoryError!void {}
    fn sysFn(_: *anyopaque) provider_mod.MemoryError![]const u8 {
        return "";
    }
    fn prefetchFn(_: *anyopaque, _: []const u8) provider_mod.MemoryError!provider_mod.Prefetch {
        return .{ .text = "" };
    }
    fn syncFn(_: *anyopaque, _: provider_mod.TurnPair) provider_mod.MemoryError!void {}
    fn shutdownFn(p: *anyopaque) void {
        const self: *Stub = @ptrCast(@alignCast(p));
        self.shutdown_calls += 1;
    }

    const vt: provider_mod.VTable = .{
        .initialize = initFn,
        .system_prompt_block = sysFn,
        .prefetch = prefetchFn,
        .sync_turn = syncFn,
        .shutdown = shutdownFn,
    };
};

test "Manager: built-in alone reports count=1 and active=builtin" {
    var b: Stub = .{};
    var m = Manager.init(testing.allocator, b.provider(.builtin, "builtin"));
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.count());

    var buf: [2]provider_mod.Provider = undefined;
    const n = m.active(&buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(provider_mod.Kind.builtin, buf[0].kind);
}

test "Manager: external registers, count goes to 2, order is builtin-first" {
    var b: Stub = .{};
    var e: Stub = .{};
    var m = Manager.init(testing.allocator, b.provider(.builtin, "builtin"));
    defer m.deinit();

    try m.registerExternal(e.provider(.external, "ext"));
    try testing.expectEqual(@as(usize, 2), m.count());

    var buf: [2]provider_mod.Provider = undefined;
    const n = m.active(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(provider_mod.Kind.builtin, buf[0].kind);
    try testing.expectEqual(provider_mod.Kind.external, buf[1].kind);
}

test "Manager: second external is rejected" {
    var b: Stub = .{};
    var e1: Stub = .{};
    var e2: Stub = .{};
    var m = Manager.init(testing.allocator, b.provider(.builtin, "builtin"));
    defer m.deinit();

    try m.registerExternal(e1.provider(.external, "ext1"));
    try testing.expectError(
        RegisterError.ExternalAlreadyRegistered,
        m.registerExternal(e2.provider(.external, "ext2")),
    );
    try testing.expectEqual(@as(usize, 2), m.count());
}

test "Manager: registering a builtin via registerExternal is rejected" {
    var b: Stub = .{};
    var b2: Stub = .{};
    var m = Manager.init(testing.allocator, b.provider(.builtin, "builtin"));
    defer m.deinit();

    try testing.expectError(
        RegisterError.BuiltinAlreadyRegistered,
        m.registerExternal(b2.provider(.builtin, "builtin2")),
    );
}

test "Manager: deinit shuts down builtin once and external once" {
    var b: Stub = .{};
    var e: Stub = .{};
    {
        var m = Manager.init(testing.allocator, b.provider(.builtin, "builtin"));
        try m.registerExternal(e.provider(.external, "ext"));
        m.deinit();
    }
    try testing.expectEqual(@as(u32, 1), b.shutdown_calls);
    try testing.expectEqual(@as(u32, 1), e.shutdown_calls);
}
