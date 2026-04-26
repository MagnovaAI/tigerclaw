//! Shared HTTP-transport helpers for LLM provider extensions.
//!
//! Provider modules open their own `std.http.Client` connections and
//! own the request lifecycle, but every backend benefits from the
//! same socket hardening: a per-read timeout so a half-open
//! connection (laptop sleep, network change, NAT rebind) surfaces in
//! seconds rather than blocking the runner thread until the kernel
//! TCP retransmit budget runs out, plus TCP keepalive so the kernel
//! detects a dead peer on its own.
//!
//! Centralised here so adding a new provider doesn't mean
//! re-discovering the right setsockopt calls.

const std = @import("std");

/// Default per-read timeout applied to streaming sockets. Picked to
/// be long enough that a slow but live model isn't killed
/// mid-thought, short enough that a stalled connection surfaces
/// quickly.
pub const default_read_timeout_secs: c_long = 60;

/// Apply `SO_RCVTIMEO` and `SO_KEEPALIVE` to a connected socket so
/// blocking reads on a stalled stream return `error.Timeout` instead
/// of hanging forever. Best-effort: any setsockopt failure is
/// ignored (the request still works, just without the safety net).
///
/// Provider adapters that obtain an `std.http.Client.Connection`
/// from `client.request(...)` should call this immediately after the
/// request opens — at that point `c.stream_reader.stream.socket.handle`
/// is the live fd.
pub fn applySocketTimeouts(fd: std.posix.fd_t, read_timeout_secs: c_long) void {
    const tv = std.posix.timeval{ .sec = read_timeout_secs, .usec = 0 };
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    const on: c_int = 1;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.KEEPALIVE,
        std.mem.asBytes(&on),
    ) catch {};
}

/// Convenience: apply the default 60s read timeout. Most callers
/// want this — only providers with unusually long streaming windows
/// (deep-thinking models, long batch operations) should pass a
/// custom value.
pub fn applyDefaultSocketTimeouts(fd: std.posix.fd_t) void {
    applySocketTimeouts(fd, default_read_timeout_secs);
}
