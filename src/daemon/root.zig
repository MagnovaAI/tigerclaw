//! Daemon subsystem front door.
//!
//! Houses the long-running gateway's process-lifecycle concerns:
//! PID file management, log file sinks, and (in a later commit)
//! fork/detach. Every module takes an `io: std.Io` and an owning
//! `Dir` so tests wire `tmpDir` instead of touching real runtime
//! paths.

const std = @import("std");

pub const pidfile = @import("pidfile.zig");
pub const logfile = @import("logfile.zig");

test {
    std.testing.refAllDecls(@import("pidfile.zig"));
    std.testing.refAllDecls(@import("logfile.zig"));
}
