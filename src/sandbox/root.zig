//! Sandbox subsystem.
//!
//! Layout (each module is self-contained — see its header for rules):
//!
//!   * `policy`  — declarative `Policy` value (fs / exec / net).
//!   * `fs`      — path-access check against `FsPolicy`.
//!   * `exec`    — argv check against `ExecPolicy`.
//!   * `net`     — host/port check against `NetPolicy`.
//!   * `detect`  — choose an OS-level backend (landlock/firejail/…),
//!                 today always `Noop`.
//!   * (this file) — `Sandbox` vtable, Noop backend, `Storage`.
//!
//! The vtable is intentionally minimal: `wrapCommand` (for backends
//! like firejail that rewrite argv), `isAvailable`, and `name`. All
//! policy *decisions* — "may this path be read?" — are made by the
//! pure functions in `fs` / `exec` / `net`, not by the backend.
//! Backends only enforce, typically via an external process wrap or
//! kernel primitives.

const std = @import("std");

pub const policy = @import("policy.zig");
pub const fs = @import("fs.zig");
pub const exec = @import("exec.zig");
pub const net = @import("net.zig");
pub const detect = @import("detect.zig");

pub const Policy = policy.Policy;
pub const FsPolicy = policy.FsPolicy;
pub const ExecPolicy = policy.ExecPolicy;
pub const NetPolicy = policy.NetPolicy;
pub const Backend = detect.Backend;

/// Vtable interface for OS-level sandbox backends.
pub const Sandbox = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Rewrite `argv` into the form required by the backend
        /// (e.g. prefixing with `firejail --net=none`). `buf` is
        /// caller-allocated scratch sized by the caller to
        /// `argv.len + N_wrap_args`. Backends that do not rewrite
        /// simply return `argv` unchanged.
        wrapCommand: *const fn (
            ctx: *anyopaque,
            argv: []const []const u8,
            buf: [][]const u8,
        ) anyerror![]const []const u8,
        isAvailable: *const fn (ctx: *anyopaque) bool,
        name: *const fn (ctx: *anyopaque) []const u8,
    };

    pub fn wrapCommand(
        self: Sandbox,
        argv: []const []const u8,
        buf: [][]const u8,
    ) ![]const []const u8 {
        return self.vtable.wrapCommand(self.ptr, argv, buf);
    }

    pub fn isAvailable(self: Sandbox) bool {
        return self.vtable.isAvailable(self.ptr);
    }

    pub fn name(self: Sandbox) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

/// No-op backend: passes argv through, always available. This is
/// the baseline every host supports; combined with the policy
/// checks in `fs`/`exec`/`net`, it provides application-layer
/// defence even when the OS has nothing richer to offer.
pub const Noop = struct {
    pub fn sandbox(self: *Noop) Sandbox {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn wrapCommand(
        _: *anyopaque,
        argv: []const []const u8,
        _: [][]const u8,
    ) ![]const []const u8 {
        return argv;
    }
    fn isAvailable(_: *anyopaque) bool {
        return true;
    }
    fn name(_: *anyopaque) []const u8 {
        return "noop";
    }

    const vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = name,
    };
};

/// Storage for backend implementations. Sized as a plain struct
/// (not a union) because Zig's tagged union would force the
/// vtable pointer to thread tag information through every call.
/// One `Storage` is owned by the harness and its lifetime is tied
/// to the sandbox handle it backs.
pub const Storage = struct {
    noop: Noop = .{},
    // Future: landlock, firejail, bubblewrap, docker slots here.
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Noop: wrapCommand passes argv through" {
    var n = Noop{};
    const sb = n.sandbox();
    const argv = &[_][]const u8{ "/bin/ls", "-la" };
    var buf: [2][]const u8 = undefined;
    const out = try sb.wrapCommand(argv, &buf);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("/bin/ls", out[0]);
    try testing.expectEqualStrings("-la", out[1]);
}

test "Noop: reports its name and availability" {
    var n = Noop{};
    const sb = n.sandbox();
    try testing.expect(sb.isAvailable());
    try testing.expectEqualStrings("noop", sb.name());
}

test {
    std.testing.refAllDecls(@import("policy.zig"));
    std.testing.refAllDecls(@import("fs.zig"));
    std.testing.refAllDecls(@import("exec.zig"));
    std.testing.refAllDecls(@import("net.zig"));
    std.testing.refAllDecls(@import("detect.zig"));
}
