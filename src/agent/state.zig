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
const types = @import("types");

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
        for (self.messages.items) |m| m.freeOwned(self.allocator);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a message, copying its content into the state's
    /// allocator. Returns the index of the new message. The content
    /// is wrapped in a single text block — agent.Agent only stores
    /// plain text turns; structured tool flows live on the
    /// LiveAgentRunner side.
    pub fn pushMessage(
        self: *AgentState,
        role: types.Role,
        content: []const u8,
    ) !usize {
        const msg = try types.Message.allocText(self.allocator, role, content);
        errdefer msg.freeOwned(self.allocator);
        try self.messages.append(self.allocator, msg);
        return self.messages.items.len - 1;
    }

    pub fn pushUser(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.user, content);
    }

    pub fn pushAssistant(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.assistant, content);
    }

    /// Append a tool-result message. With the wire-Role refactor,
    /// `tool` is no longer a wire role — tool results ride on user
    /// messages via tool_result content blocks. agent.Agent doesn't
    /// build structured tool flows yet, so we collapse to user-text
    /// for now (same flat-string treatment as before).
    pub fn pushTool(self: *AgentState, content: []const u8) !usize {
        return self.pushMessage(.user, content);
    }

    pub fn history(self: *const AgentState) []const types.Message {
        return self.messages.items;
    }

    /// Replace the entire message list with `new`. Frees every old
    /// message and the old backing array. The caller hands over
    /// ownership of `new` (and every `Message` inside it) — both
    /// must have been allocated with `self.allocator`. Used by
    /// context-engine compaction: the engine returns a freshly-
    /// owned slice, and the agent swaps it into the state in one
    /// step so no slice in the old array escapes.
    pub fn replaceMessages(
        self: *AgentState,
        new: []types.Message,
    ) !void {
        for (self.messages.items) |m| m.freeOwned(self.allocator);
        self.messages.deinit(self.allocator);
        self.messages = .empty;
        try self.messages.appendSlice(self.allocator, new);
        self.allocator.free(new);
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
    try testing.expectEqualStrings("hi", h[0].flatText());
    // pushTool now collapses to user role since tool isn't a wire role anymore.
    try testing.expectEqual(types.Role.user, h[2].role);
}

test "AgentState: pushed strings are independent copies" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    var buf = [_]u8{ 'a', 'b', 'c' };
    _ = try s.pushUser(&buf);
    buf[0] = 'X'; // mutate the caller's buffer

    try testing.expectEqualStrings("abc", s.history()[0].flatText());
}

test "AgentState: replaceMessages frees old and adopts new" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    _ = try s.pushUser("old1");
    _ = try s.pushAssistant("old2");

    const new = try testing.allocator.alloc(types.Message, 1);
    new[0] = try types.Message.allocText(testing.allocator, .user, "fresh");

    try s.replaceMessages(new);

    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expectEqualStrings("fresh", s.history()[0].flatText());
}

test "AgentState: iteration counter bumps and resets" {
    var s = AgentState.init(testing.allocator);
    defer s.deinit();

    try testing.expectEqual(@as(u32, 1), s.bumpIteration());
    try testing.expectEqual(@as(u32, 2), s.bumpIteration());
    s.startNewTurn();
    try testing.expectEqual(@as(u32, 0), s.iteration);
}
