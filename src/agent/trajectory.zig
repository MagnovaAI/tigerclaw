//! Per-turn trajectory log.
//!
//! `AgentState` owns the transcript the LLM sees. The trajectory
//! owns the *diagnostic* log of what actually happened during a
//! turn: one entry per react iteration, each recording the stop
//! reason, the token usage, and any tool calls fired. Downstream
//! consumers (the diagnostics buffer, the trace subsystem, a CLI
//! `--debug` dump) lift trajectories into their own formats.
//!
//! Keeping this separate from `AgentState` avoids two pitfalls:
//!
//!   * It would be wrong to round-trip diagnostic fields through
//!     the LLM's own input — the model does not need to see its
//!     prior stop reasons or usage tallies.
//!   * `AgentState` is serialised into session files (via
//!     `harness.Session`). Trajectories are ephemeral; lifting
//!     them in would bloat the session JSON with run-specific
//!     noise.

const std = @import("std");
const types = @import("../types/root.zig");

pub const IterationRecord = struct {
    iteration: u32,
    stop_reason: types.StopReason,
    assistant_bytes: u32,
    tool_calls: u16,
    usage: types.TokenUsage,
};

pub const Trajectory = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(IterationRecord),

    pub fn init(allocator: std.mem.Allocator) Trajectory {
        return .{ .allocator = allocator, .records = .empty };
    }

    pub fn deinit(self: *Trajectory) void {
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Trajectory, record: IterationRecord) !void {
        try self.records.append(self.allocator, record);
    }

    pub fn len(self: *const Trajectory) usize {
        return self.records.items.len;
    }

    pub fn items(self: *const Trajectory) []const IterationRecord {
        return self.records.items;
    }

    /// Reset the log without freeing the backing storage. Called
    /// at the start of a new user turn.
    pub fn clear(self: *Trajectory) void {
        self.records.clearRetainingCapacity();
    }

    pub const Summary = struct {
        iterations: u32,
        total_assistant_bytes: u32,
        total_tool_calls: u32,
        total_usage: types.TokenUsage,
    };

    /// Reduce the records to a single summary row. Cheap; called
    /// at end-of-turn to drop into the diagnostics buffer.
    pub fn summary(self: *const Trajectory) Summary {
        var s = Summary{
            .iterations = 0,
            .total_assistant_bytes = 0,
            .total_tool_calls = 0,
            .total_usage = .{},
        };
        for (self.records.items) |r| {
            s.iterations +|= 1;
            s.total_assistant_bytes +|= r.assistant_bytes;
            s.total_tool_calls +|= @as(u32, r.tool_calls);
            s.total_usage.input +|= r.usage.input;
            s.total_usage.output +|= r.usage.output;
            s.total_usage.cache_read +|= r.usage.cache_read;
            s.total_usage.cache_write +|= r.usage.cache_write;
        }
        return s;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Trajectory: push, items, summary" {
    var t = Trajectory.init(testing.allocator);
    defer t.deinit();

    try t.push(.{
        .iteration = 1,
        .stop_reason = .tool_use,
        .assistant_bytes = 0,
        .tool_calls = 2,
        .usage = .{ .input = 100, .output = 10 },
    });
    try t.push(.{
        .iteration = 2,
        .stop_reason = .end_turn,
        .assistant_bytes = 42,
        .tool_calls = 0,
        .usage = .{ .input = 30, .output = 50 },
    });

    try testing.expectEqual(@as(usize, 2), t.len());
    const s = t.summary();
    try testing.expectEqual(@as(u32, 2), s.iterations);
    try testing.expectEqual(@as(u32, 42), s.total_assistant_bytes);
    try testing.expectEqual(@as(u32, 2), s.total_tool_calls);
    try testing.expectEqual(@as(u32, 130), s.total_usage.input);
    try testing.expectEqual(@as(u32, 60), s.total_usage.output);
}

test "Trajectory: clear empties the log but keeps capacity" {
    var t = Trajectory.init(testing.allocator);
    defer t.deinit();

    try t.push(.{
        .iteration = 1,
        .stop_reason = .end_turn,
        .assistant_bytes = 0,
        .tool_calls = 0,
        .usage = .{},
    });
    t.clear();
    try testing.expectEqual(@as(usize, 0), t.len());
    try testing.expectEqual(@as(u32, 0), t.summary().iterations);
}
