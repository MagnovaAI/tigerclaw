//! Per-session todo list. Lives in memory on the LiveAgentRunner;
//! gets surfaced to the TUI (later phase) as a checkbox widget.
//!
//! Replace semantics: every call wipes the previous list and stores
//! the new one. No partial updates, no patches.

const std = @import("std");

pub const TodoStatus = enum { pending, in_progress, done };

pub const TodoItem = struct {
    title: []const u8,
    active_form: ?[]const u8,
    status: TodoStatus,
};

pub const TodoError = error{
    MultipleInProgress,
    EmptyTitle,
    OversizeTitle,
    TooManyItems,
    InvalidStatus,
} || std.mem.Allocator.Error;

/// Hard cap on items per list -- keeps a runaway model from blowing
/// memory. 50 is well above any realistic plan length.
pub const MAX_ITEMS: usize = 50;
/// Hard cap on title bytes. Active-form bound is the same.
pub const MAX_TITLE_BYTES: usize = 200;

const SessionTodos = struct {
    items: []TodoItem = &.{},

    pub fn deinit(self: *SessionTodos, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.title);
            if (item.active_form) |a| allocator.free(a);
        }
        if (self.items.len > 0) allocator.free(self.items);
        self.items = &.{};
    }
};

pub const TodoState = struct {
    sessions: std.StringHashMapUnmanaged(SessionTodos) = .empty,

    pub fn init() TodoState {
        return .{};
    }

    pub fn deinit(self: *TodoState, allocator: std.mem.Allocator) void {
        var it = self.sessions.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.sessions.deinit(allocator);
    }

    /// Replace the entire list for a session. Validates atomically --
    /// on failure, the prior list is left untouched.
    pub fn set(
        self: *TodoState,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        items: []const TodoItem,
    ) TodoError!void {
        try validate(items);

        // Allocate the new copy first so we can roll back the prior
        // list only after the new one is owned.
        const new_items = try allocator.alloc(TodoItem, items.len);
        errdefer allocator.free(new_items);
        var dup_count: usize = 0;
        errdefer {
            for (new_items[0..dup_count]) |it| {
                allocator.free(it.title);
                if (it.active_form) |a| allocator.free(a);
            }
        }
        for (items, 0..) |item, idx| {
            const t = try allocator.dupe(u8, item.title);
            const a: ?[]const u8 = if (item.active_form) |s| try allocator.dupe(u8, s) else null;
            new_items[idx] = .{ .title = t, .active_form = a, .status = item.status };
            dup_count += 1;
        }

        if (!self.sessions.contains(session_id)) {
            const owned_id = try allocator.dupe(u8, session_id);
            errdefer allocator.free(owned_id);
            try self.sessions.put(allocator, owned_id, .{});
        }
        const session = self.sessions.getPtr(session_id).?;
        session.deinit(allocator);
        session.* = .{ .items = new_items };
    }

    pub fn get(self: *TodoState, session_id: []const u8) []const TodoItem {
        const session = self.sessions.getPtr(session_id) orelse return &.{};
        return session.items;
    }
};

fn validate(items: []const TodoItem) TodoError!void {
    if (items.len > MAX_ITEMS) return error.TooManyItems;
    var in_progress_count: u32 = 0;
    for (items) |item| {
        if (item.title.len == 0) return error.EmptyTitle;
        if (item.title.len > MAX_TITLE_BYTES) return error.OversizeTitle;
        if (item.active_form) |a| {
            if (a.len > MAX_TITLE_BYTES) return error.OversizeTitle;
        }
        if (item.status == .in_progress) in_progress_count += 1;
    }
    if (in_progress_count > 1) return error.MultipleInProgress;
}

pub const StatusCounts = struct {
    pending: u32 = 0,
    in_progress: u32 = 0,
    done: u32 = 0,
};

pub fn countByStatus(items: []const TodoItem) StatusCounts {
    var c: StatusCounts = .{};
    for (items) |item| switch (item.status) {
        .pending => c.pending += 1,
        .in_progress => c.in_progress += 1,
        .done => c.done += 1,
    };
    return c;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "validate: rejects multiple in_progress" {
    const items = [_]TodoItem{
        .{ .title = "a", .active_form = null, .status = .in_progress },
        .{ .title = "b", .active_form = null, .status = .in_progress },
    };
    try testing.expectError(error.MultipleInProgress, validate(&items));
}

test "validate: rejects empty title" {
    const items = [_]TodoItem{
        .{ .title = "", .active_form = null, .status = .pending },
    };
    try testing.expectError(error.EmptyTitle, validate(&items));
}

test "validate: rejects oversize title" {
    const big = "x" ** (MAX_TITLE_BYTES + 1);
    const items = [_]TodoItem{
        .{ .title = big, .active_form = null, .status = .pending },
    };
    try testing.expectError(error.OversizeTitle, validate(&items));
}

test "validate: rejects > MAX_ITEMS" {
    var items: [MAX_ITEMS + 1]TodoItem = undefined;
    for (&items) |*it| it.* = .{ .title = "x", .active_form = null, .status = .pending };
    try testing.expectError(error.TooManyItems, validate(&items));
}

test "set: replace semantics" {
    var state = TodoState.init();
    defer state.deinit(testing.allocator);

    const a = [_]TodoItem{
        .{ .title = "old1", .active_form = null, .status = .pending },
        .{ .title = "old2", .active_form = null, .status = .pending },
    };
    try state.set(testing.allocator, "sess1", &a);
    try testing.expectEqual(@as(usize, 2), state.get("sess1").len);

    const b = [_]TodoItem{
        .{ .title = "new", .active_form = null, .status = .done },
    };
    try state.set(testing.allocator, "sess1", &b);
    try testing.expectEqual(@as(usize, 1), state.get("sess1").len);
    try testing.expectEqualStrings("new", state.get("sess1")[0].title);
}

test "set: empty list clears" {
    var state = TodoState.init();
    defer state.deinit(testing.allocator);

    const a = [_]TodoItem{
        .{ .title = "x", .active_form = null, .status = .pending },
    };
    try state.set(testing.allocator, "sess1", &a);
    try state.set(testing.allocator, "sess1", &.{});
    try testing.expectEqual(@as(usize, 0), state.get("sess1").len);
}

test "countByStatus: tallies correctly" {
    const items = [_]TodoItem{
        .{ .title = "a", .active_form = null, .status = .pending },
        .{ .title = "b", .active_form = null, .status = .in_progress },
        .{ .title = "c", .active_form = null, .status = .done },
        .{ .title = "d", .active_form = null, .status = .done },
    };
    const c = countByStatus(&items);
    try testing.expectEqual(@as(u32, 1), c.pending);
    try testing.expectEqual(@as(u32, 1), c.in_progress);
    try testing.expectEqual(@as(u32, 2), c.done);
}
