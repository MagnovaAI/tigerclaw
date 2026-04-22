//! Gateway subsystem front door.
//!
//! Houses the HTTP façade the CLI talks to. This commit ships pure
//! routing; the `std.http.Server` wrapper, middleware, and endpoint
//! handlers land in later commits.

const std = @import("std");

pub const router = @import("router.zig");
pub const http = @import("http.zig");
pub const dispatcher = @import("dispatcher.zig");

pub const Method = router.Method;
pub const Route = router.Route;
pub const Match = router.Match;
pub const Resolved = router.Resolved;
pub const Request = http.Request;
pub const Response = http.Response;
pub const Status = http.Status;
pub const Header = http.Header;

test {
    std.testing.refAllDecls(@import("router.zig"));
    std.testing.refAllDecls(@import("http.zig"));
    std.testing.refAllDecls(@import("dispatcher.zig"));
}
