//! A single conversational turn.
//!
//! A `Turn` is the atomic unit the harness commits to session state:
//! one user input paired with the assistant response it produced. The
//! pair is intentionally flat — future phases (tool calls, scratchpads,
//! cost) extend this with optional side channels rather than changing
//! the primary two-message shape.

const std = @import("std");
const types = @import("../types/root.zig");

/// One user → assistant exchange.
///
/// Timestamps are captured in nanoseconds from the injected `Clock`.
/// `started_at_ns` is stamped when the harness accepts the user input;
/// `finished_at_ns` is stamped when the assistant response is recorded.
pub const Turn = struct {
    /// Zero-based ordinal within the session. Equal to
    /// `state.turn_count` at the moment the turn was begun.
    index: u32,
    started_at_ns: i128,
    finished_at_ns: i128,
    user: types.Message,
    assistant: types.Message,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Turn: JSON roundtrip preserves ordering and roles" {
    const t = Turn{
        .index = 3,
        .started_at_ns = 10,
        .finished_at_ns = 20,
        .user = .{ .role = .user, .content = "hi" },
        .assistant = .{ .role = .assistant, .content = "hello" },
    };

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, t, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Turn, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 3), parsed.value.index);
    try testing.expectEqual(@as(i128, 10), parsed.value.started_at_ns);
    try testing.expectEqual(@as(i128, 20), parsed.value.finished_at_ns);
    try testing.expectEqual(types.Role.user, parsed.value.user.role);
    try testing.expectEqual(types.Role.assistant, parsed.value.assistant.role);
    try testing.expectEqualStrings("hi", parsed.value.user.content);
    try testing.expectEqualStrings("hello", parsed.value.assistant.content);
}
