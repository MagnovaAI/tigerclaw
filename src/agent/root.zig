//! Agent subsystem: react loop + state + tool-executor vtable.
//!
//! Submodules:
//!   * `vtable` — `ToolExecutor` interface and `DenyExecutor`.
//!   * `state`  — `AgentState` (mutable transcript + iteration counter).
//!   * `react`  — single-step provider call + tool dispatch.
//!   * `loop`   — iterative driver with `max_iterations` cap.
//!   * `agent`  — facade bundling provider, executor, state, and loop.
//!
//! The tool registry (Commit 39) implements the `ToolExecutor`
//! interface for real tools. Until then, a `DenyExecutor` or a
//! test-local scripted executor satisfies the contract.

const std = @import("std");

pub const vtable = @import("vtable.zig");
pub const state = @import("state.zig");
pub const react = @import("react.zig");
pub const loop = @import("loop.zig");
pub const agent = @import("agent.zig");

pub const ToolExecutor = vtable.ToolExecutor;
pub const DenyExecutor = vtable.DenyExecutor;
pub const AgentState = state.AgentState;
pub const StepOutcome = react.StepOutcome;
pub const LoopConfig = loop.Config;
pub const RunOutcome = loop.RunOutcome;
pub const TerminationReason = loop.TerminationReason;
pub const Agent = agent.Agent;
pub const AgentOptions = agent.Options;

test {
    std.testing.refAllDecls(@import("vtable.zig"));
    std.testing.refAllDecls(@import("state.zig"));
    std.testing.refAllDecls(@import("react.zig"));
    std.testing.refAllDecls(@import("loop.zig"));
    std.testing.refAllDecls(@import("agent.zig"));
}
