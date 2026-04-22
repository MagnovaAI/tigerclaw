//! Compaction hints carried forward when history is trimmed.
//!
//! When the compactor drops or summarises old turns, it attaches
//! a set of hints to the next prompt so the model retains
//! key facts without re-ingesting every byte. A hint is a short,
//! model-facing string — "prior goal: refactor auth module",
//! "open files: /x.zig, /y.zig", "earlier decision: use mutex
//! over atomic".
//!
//! Hints are deliberately a flat list rather than structured
//! metadata because the model consumes them as plain prose. The
//! compactor emits `[compacted]\n<hint>\n<hint>\n...` blocks.

const std = @import("std");

pub const Hints = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Hints {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *Hints) void {
        for (self.items.items) |h| self.allocator.free(h);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a hint. The string is heap-duplicated.
    pub fn push(self: *Hints, hint: []const u8) !void {
        const copy = try self.allocator.dupe(u8, hint);
        errdefer self.allocator.free(copy);
        try self.items.append(self.allocator, copy);
    }

    pub fn len(self: *const Hints) usize {
        return self.items.items.len;
    }

    pub fn slice(self: *const Hints) []const []const u8 {
        return self.items.items;
    }

    /// Render the hints as a single compaction block suitable to
    /// prepend to the assistant prompt. Returns a caller-owned
    /// byte slice. Empty hints list produces an empty string.
    pub fn render(self: *const Hints, allocator: std.mem.Allocator) ![]u8 {
        if (self.items.items.len == 0) return allocator.dupe(u8, "");
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "[compacted]\n");
        for (self.items.items) |h| {
            try buf.appendSlice(allocator, h);
            try buf.append(allocator, '\n');
        }
        return buf.toOwnedSlice(allocator);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Hints: push and slice" {
    var h = Hints.init(testing.allocator);
    defer h.deinit();

    try h.push("a");
    try h.push("b");
    try testing.expectEqual(@as(usize, 2), h.len());
    try testing.expectEqualStrings("a", h.slice()[0]);
}

test "Hints.render: formats a compaction block" {
    var h = Hints.init(testing.allocator);
    defer h.deinit();
    try h.push("open file: /x");
    try h.push("goal: refactor");

    const rendered = try h.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.startsWith(u8, rendered, "[compacted]\n"));
    try testing.expect(std.mem.indexOf(u8, rendered, "open file: /x") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "goal: refactor") != null);
}

test "Hints.render: empty list produces empty string" {
    var h = Hints.init(testing.allocator);
    defer h.deinit();
    const rendered = try h.render(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqual(@as(usize, 0), rendered.len);
}
