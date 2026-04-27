//! Cheap "is the gateway daemon up?" check.
//!
//! TCP-connects to the gateway's listen address with a tight
//! timeout. Used by the TUI status bar to flip `gateway: on/off`
//! without standing up a real daemon yet — when an actual
//! tigerclaw daemon process is running on the canonical port,
//! this probe returns `true` and the bar reads `on`.
//!
//! Failure modes the probe must NOT crash on:
//!   - port unbound (ConnectionRefused)
//!   - host unroutable (NetworkUnreachable)
//!   - allocator pressure (allocator returns OutOfMemory)
//! Each maps to "off" without surfacing the error to the caller —
//! the status bar prefers a quiet falsey over a loud panic.

const std = @import("std");

/// Default canonical local gateway address. Matches the default in
/// `src/cli/root.zig` so the TUI and the CLI agent verb agree on
/// the port without needing a config dance.
pub const default_host: []const u8 = "127.0.0.1";
pub const default_port: u16 = 8765;

/// True when something accepts a TCP connection on the given
/// address. Closes the socket immediately — the probe does not
/// speak HTTP, it only confirms the listener exists. False on
/// every error, including unreachable host. Needs an `Io`
/// because Zig 0.16 net is `Io`-scoped.
///
/// Note: the stdlib's POSIX `netConnectIp` does not yet honour
/// `timeout` (it panics on the unimplemented path), so we leave the
/// timeout `.none`. Localhost connect fails immediately on
/// `ECONNREFUSED`; remote-host probing isn't a use case here.
pub fn probe(io: std.Io, host: []const u8, port: u16) bool {
    const addr = std.Io.net.IpAddress.parse(host, port) catch return false;
    var stream = addr.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    }) catch return false;
    stream.close(io);
    return true;
}

/// Convenience: probe the canonical local gateway.
pub fn probeDefault(io: std.Io) bool {
    return probe(io, default_host, default_port);
}

const testing = std.testing;

test "probe: refuses non-listening port returns false" {
    // Port 1 reserved for tcpmux; nothing in the test env listens
    // there. Confirms the error path collapses to a quiet `false`.
    try testing.expectEqual(false, probe(testing.io, "127.0.0.1", 1));
}
