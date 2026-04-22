//! Running state of one react turn.
//!
//! The agent loop feeds a growing list of `Message`s into the
//! provider on every iteration. `AgentState` owns that list and
//! its backing allocations, plus the per-turn bookkeeping (the
//! iteration counter, the last provider response, a record of
//! tool calls seen).
//!
//! Ownership rule: every slice stored in `messages` is heap-
//! duplicated into the state's allocator. Caller strings passed
//! to `pushUser` / `pushAssistant` / `pushTool` are copied so they
//! may be freed or mutated afterwards.

const std = @import("std");
const types = @import("../types/root.zig");

pub const AgentState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(types.Message),
    iteration: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) AgentState {
        return .{
            .allocator = allocator,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |m| self.allocator.free(m.content);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a message, copying its content into the state's
    /// allocator. Returns the index of the new message.
    pub fn pushMessage(
        self: *AgentState,
        role: types.Role,
        content: []const u8,
    ) !usize {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        try self.messages.append(self.allocator, .{ .role = role, .content = copy });
        return self.messages.items.len - 1;
    }

    pub fn pushUser(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.user, content);
    }

    pub fn pushAssistant(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.assistant, content);
    }

    /// Append a tool-result message. The payload is the rendered
    /// outcome string the provider will see on the next turn.
    pub fn pushTool(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.tool, content);
    }

    pub fn history(self: *const AgentState) []const types.Message {
        return self.messages.items;
    }

    pub fn len(self: *const AgentState) usize {
        return self.messages.items.len;
    }

    pub fn bumpIteration(self: *AgentState) u32 {
        self.iteration += 1;
        return self.iteration;
    }

    /// Reset iteration counter without dropping history. Used when
    /// a new user turn begins in a persistent session.
    pub fn startNewTurn(self: *AgentState) void {
        self.iteration = 0;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "AgentState: push round-trips role and content" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    _ = try s.pushUser("hi");
    _ = try s.pushAssistant("hello");
    _ = try s.pushTool("{\"ok\":1}");

    const h = s.history();
    try testing.expectEqual(@as(usize, 3), h.len);
    try testing.expectEqual(types.Role.user, h[0].role);
    try testing.expectEqualStrings("hi", h[0].content);
    try testing.expectEqual(types.Role.tool, h[2].role);
}

test "AgentState: pushed strings are independent copies" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    var buf = [_]u8{ 'a', 'b', 'c' };
    _ = try s.pushUser(&buf);
    buf[0] = 'X'; // mutate the caller's buffer

    try testing.expectEqualStrings("abc", s.history()[0].content);
}

test "AgentState: iteration counter bumps and resets" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    try testing.expectEqual(@as(u32, 1), s.bumpIteration());
    try testing.expectEqual(@as(u32, 2), s.bumpIteration());
    s.startNewTurn();
    try testing.expectEqual(@as(u32, 0), s.iteration);
}
