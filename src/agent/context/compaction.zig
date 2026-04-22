//! Transcript compaction.
//!
//! When the context window is under pressure, the compactor takes
//! the current history and emits a shortened replacement. The
//! default strategy is "keep system + first N messages + last M
//! messages; drop the middle and synthesise a hint that
//! summarises what was dropped".
//!
//! The compactor does not call the model for summarisation. A
//! "smart" LLM-assisted compactor is conceivable but dangerous
//! during a budget-pressure event: we do NOT want to spend more
//! tokens to shrink the prompt. This layer is mechanical.
//!
//! Output is a new owned message slice + optional hint block,
//! never a mutation of the caller's history.

const std = @import("std");
const types = @import("../../types/root.zig");
const hints_mod = @import("hints.zig");

pub const Policy = struct {
    /// Keep the first K messages verbatim (typically system +
    /// original user prompt). `0` keeps nothing.
    keep_head: usize = 1,
    /// Keep the last K messages verbatim (the "recent past" the
    /// model actively references).
    keep_tail: usize = 4,
};

pub const Result = struct {
    /// Caller-owned compacted message list.
    messages: []types.Message,
    /// How many messages were dropped and folded into the hint.
    dropped: usize,
    /// Owning reference to the synthesised hint block. Empty if
    /// nothing was dropped. Caller frees alongside messages.
    hint: []u8,
};

pub fn deinitResult(allocator: std.mem.Allocator, r: Result) void {
    for (r.messages) |m| allocator.free(m.content);
    allocator.free(r.messages);
    allocator.free(r.hint);
}

/// Compact `history` according to `policy`. Messages that survive
/// are duplicated into `allocator`; the caller can free the
/// original at will.
pub fn compact(
    allocator: std.mem.Allocator,
    history: []const types.Message,
    policy: Policy,
) !Result {
    const head_n = @min(policy.keep_head, history.len);
    const tail_start = if (history.len > policy.keep_tail)
        history.len - policy.keep_tail
    else
        head_n;
    const effective_tail_start = @max(head_n, tail_start);
    const kept_total = head_n + (history.len - effective_tail_start);
    const dropped = history.len - kept_total;

    var messages = try allocator.alloc(types.Message, kept_total);
    errdefer allocator.free(messages);

    var written: usize = 0;
    errdefer for (messages[0..written]) |m| allocator.free(m.content);

    // Head
    for (history[0..head_n]) |m| {
        const copy = try allocator.dupe(u8, m.content);
        messages[written] = .{ .role = m.role, .content = copy };
        written += 1;
    }
    // Tail
    for (history[effective_tail_start..]) |m| {
        const copy = try allocator.dupe(u8, m.content);
        messages[written] = .{ .role = m.role, .content = copy };
        written += 1;
    }

    // Hint block describing what was dropped. We keep it short on
    // purpose — a paragraph the model will skim.
    var hint: []u8 = try allocator.alloc(u8, 0);
    if (dropped > 0) {
        allocator.free(hint);
        var h = hints_mod.Hints.init(allocator);
        defer h.deinit();
        var buf: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(
            &buf,
            "dropped {d} older message(s) to fit context window",
            .{dropped},
        );
        try h.push(s);
        hint = try h.render(allocator);
    }

    return .{
        .messages = messages,
        .dropped = dropped,
        .hint = hint,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "compact: short history is passed through unchanged" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "1" },
        .{ .role = .assistant, .content = "2" },
    };
    const r = try compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 4 });
    defer deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 2), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqual(@as(usize, 0), r.hint.len);
}

test "compact: trims middle when history exceeds head+tail" {
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "head" },
        .{ .role = .assistant, .content = "mid1" },
        .{ .role = .user, .content = "mid2" },
        .{ .role = .assistant, .content = "mid3" },
        .{ .role = .user, .content = "tail1" },
        .{ .role = .assistant, .content = "tail2" },
    };
    const r = try compact(testing.allocator, &msgs, .{ .keep_head = 1, .keep_tail = 2 });
    defer deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 3), r.messages.len);
    try testing.expectEqualStrings("head", r.messages[0].content);
    try testing.expectEqualStrings("tail1", r.messages[1].content);
    try testing.expectEqualStrings("tail2", r.messages[2].content);
    try testing.expectEqual(@as(usize, 3), r.dropped);
    try testing.expect(std.mem.indexOf(u8, r.hint, "dropped 3") != null);
}

test "compact: keep_head larger than history is clamped" {
    const msgs = [_]types.Message{.{ .role = .user, .content = "only" }};
    const r = try compact(testing.allocator, &msgs, .{ .keep_head = 10, .keep_tail = 10 });
    defer deinitResult(testing.allocator, r);

    try testing.expectEqual(@as(usize, 1), r.messages.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
}
