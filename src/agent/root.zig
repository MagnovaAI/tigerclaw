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
pub const prompt_builder = @import("prompt_builder.zig");
pub const prompt_caching = @import("prompt_caching.zig");
pub const tool_selection = @import("tool_selection.zig");
pub const trajectory = @import("trajectory.zig");

pub const ToolExecutor = vtable.ToolExecutor;
pub const DenyExecutor = vtable.DenyExecutor;
pub const AgentState = state.AgentState;
pub const StepOutcome = react.StepOutcome;
pub const LoopConfig = loop.Config;
pub const RunOutcome = loop.RunOutcome;
pub const TerminationReason = loop.TerminationReason;
pub const Agent = agent.Agent;
pub const AgentOptions = agent.Options;
pub const PromptInput = prompt_builder.Input;
pub const CacheConfig = prompt_caching.Config;
pub const CachePlan = prompt_caching.PlanResult;
pub const CacheBreakpoint = prompt_caching.Breakpoint;
pub const CachePosition = prompt_caching.Position;
pub const ToolSpec = tool_selection.ToolSpec;
pub const Selector = tool_selection.Selector;
pub const Trajectory = trajectory.Trajectory;
pub const IterationRecord = trajectory.IterationRecord;

test {
    std.testing.refAllDecls(@import("vtable.zig"));
    std.testing.refAllDecls(@import("state.zig"));
    std.testing.refAllDecls(@import("react.zig"));
    std.testing.refAllDecls(@import("loop.zig"));
    std.testing.refAllDecls(@import("agent.zig"));
    std.testing.refAllDecls(@import("prompt_builder.zig"));
    std.testing.refAllDecls(@import("prompt_caching.zig"));
    std.testing.refAllDecls(@import("tool_selection.zig"));
    std.testing.refAllDecls(@import("trajectory.zig"));
}
