//! Harness subsystem: owns session lifecycle (create / resume / save),
//! resource budgets, cooperative interrupts, and respawn policy.
//!
//! Modules:
//!   - state:     on-disk snapshot (JSON).
//!   - turn:      one user→assistant exchange.
//!   - session:   mutable owner of live conversation history.
//!   - harness:   top-level orchestrator used by CLI entry points.
//!   - budget:    per-session turn/token/cost caps.
//!   - interrupt: atomic cooperative cancellation flag.
//!   - respawn:   policy for restarting a session after a fatal turn.
//!
//! Sandbox, permissions, cost ledger, and the react loop plug into
//! these primitives in later commits.

const std = @import("std");

pub const state = @import("state.zig");
pub const turn = @import("turn.zig");
pub const session = @import("session.zig");
pub const harness = @import("harness.zig");
pub const budget = @import("budget.zig");
pub const interrupt = @import("interrupt.zig");
pub const respawn = @import("respawn.zig");
pub const mode_policy = @import("mode_policy.zig");
pub const bench_guards = @import("bench_guards.zig");
pub const shared_ledger = @import("shared_ledger.zig");

pub const State = state.State;
pub const Turn = turn.Turn;
pub const Session = session.Session;
pub const Harness = harness.Harness;
pub const HarnessOptions = harness.Options;
pub const Budget = budget.Budget;
pub const BudgetLimits = budget.Limits;
pub const Interrupt = interrupt.Interrupt;
pub const RespawnController = respawn.Controller;
pub const RespawnPolicy = respawn.Policy;
pub const Mode = mode_policy.Mode;
pub const ModePolicy = mode_policy.Policy;
pub const GuardedProvider = bench_guards.GuardedProvider;
pub const BenchHarnessBuilder = bench_guards.BenchHarnessBuilder;
pub const SharedLedger = shared_ledger.SharedLedger;
pub const HeldReservation = shared_ledger.Held;

test {
    std.testing.refAllDecls(@import("state.zig"));
    std.testing.refAllDecls(@import("turn.zig"));
    std.testing.refAllDecls(@import("session.zig"));
    std.testing.refAllDecls(@import("harness.zig"));
    std.testing.refAllDecls(@import("budget.zig"));
    std.testing.refAllDecls(@import("interrupt.zig"));
    std.testing.refAllDecls(@import("respawn.zig"));
    std.testing.refAllDecls(@import("mode_policy.zig"));
    std.testing.refAllDecls(@import("bench_guards.zig"));
    std.testing.refAllDecls(@import("shared_ledger.zig"));
}
