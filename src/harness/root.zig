//! Harness subsystem: owns session lifecycle (create / resume / save).
//!
//! Modules land here incrementally:
//!   - state: on-disk snapshot (JSON).
//!   - turn:  one user→assistant exchange.
//!   - session: mutable owner of live conversation history.
//!   - harness: top-level orchestrator used by CLI entry points.
//!
//! Budget, interrupt/respawn, sandbox, permissions, cost, and the
//! react loop plug into this surface in later commits.

const std = @import("std");

pub const state = @import("state.zig");
pub const turn = @import("turn.zig");
pub const session = @import("session.zig");
pub const harness = @import("harness.zig");

pub const State = state.State;
pub const Turn = turn.Turn;
pub const Session = session.Session;
pub const Harness = harness.Harness;
pub const HarnessOptions = harness.Options;

test {
    std.testing.refAllDecls(@import("state.zig"));
    std.testing.refAllDecls(@import("turn.zig"));
    std.testing.refAllDecls(@import("session.zig"));
    std.testing.refAllDecls(@import("harness.zig"));
}
