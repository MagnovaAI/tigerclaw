//! Gateway subsystem front door.
//!
//! Houses the HTTP façade the CLI talks to. This commit ships pure
//! routing; the `std.http.Server` wrapper, middleware, and endpoint
//! handlers land in later commits.

const std = @import("std");

pub const router = @import("router.zig");

pub const Method = router.Method;
pub const Route = router.Route;
pub const Match = router.Match;
pub const Resolved = router.Resolved;

test {
    std.testing.refAllDecls(@import("router.zig"));
}
