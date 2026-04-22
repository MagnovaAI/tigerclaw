//! On-disk session state.
//!
//! `State` is the serialisable snapshot of one conversation: identity,
//! timestamps, and the ordered list of turns that have been committed.
//! It is the canonical record that `--resume` rehydrates from disk.
//!
//! The format is plain JSON. We deliberately keep the schema small and
//! append-only: later phases (budget, cost ledger, permissions) extend
//! the envelope with new optional fields, so older state files stay
//! forward-readable. A `schema_version` integer is stamped on every
//! write so breaking changes are detectable.

const std = @import("std");
const types = @import("../types/root.zig");
const turn_mod = @import("turn.zig");

/// Current on-disk schema version. Bump only on breaking layout changes;
/// additive fields do not require a bump because `std.json` ignores
/// unknown members when `ignore_unknown_fields = true`.
pub const schema_version: u32 = 1;

/// Snapshot of a session as persisted to disk.
///
/// Field ownership: every slice in a `State` owned by the caller (usually
/// the `Session`) is allocated with the session's allocator and freed
/// together in `deinit`. Loaded states own their allocations through the
/// `std.json.Parsed` wrapper returned by `load`.
pub const State = struct {
    schema_version: u32 = schema_version,
    /// Opaque, stable identifier. Generated from the determinism seed so
    /// replays produce identical session ids.
    id: []const u8,
    /// Monotonically increasing count of turns committed to this session.
    turn_count: u32 = 0,
    /// Wall-clock (ns) at session creation. Written once.
    created_at_ns: i128,
    /// Wall-clock (ns) of the most recent successful save.
    updated_at_ns: i128,
    /// Ordered conversation history. Each turn bundles the user input and
    /// the assistant response that followed it.
    turns: []const turn_mod.Turn = &.{},
};

/// Serialise `state` to `writer` as pretty-printed JSON.
pub fn writeJson(state: State, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, writer);
}

/// Serialise `state` to a caller-owned byte slice.
pub fn stringify(allocator: std.mem.Allocator, state: State) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, state, .{ .whitespace = .indent_2 });
}

/// Parse a JSON buffer into an owned `State`. The returned `Parsed`
/// arena owns every slice inside the state — the caller must hold it
/// alive for as long as the state is read, and call `.deinit()` once
/// done. Unknown fields are ignored so forward-compatible files load
/// cleanly against older binaries.
pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(State) {
    return std.json.parseFromSlice(State, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "State: JSON roundtrip preserves identity and turns" {
    const turns = [_]turn_mod.Turn{
        .{
            .index = 0,
            .started_at_ns = 100,
            .finished_at_ns = 200,
            .user = .{ .role = .user, .content = "ping" },
            .assistant = .{ .role = .assistant, .content = "pong" },
        },
    };
    const original = State{
        .id = "session-abc",
        .turn_count = 1,
        .created_at_ns = 50,
        .updated_at_ns = 200,
        .turns = &turns,
    };

    const json_bytes = try stringify(testing.allocator, original);
    defer testing.allocator.free(json_bytes);

    const parsed = try parse(testing.allocator, json_bytes);
    defer parsed.deinit();

    try testing.expectEqual(schema_version, parsed.value.schema_version);
    try testing.expectEqualStrings("session-abc", parsed.value.id);
    try testing.expectEqual(@as(u32, 1), parsed.value.turn_count);
    try testing.expectEqual(@as(usize, 1), parsed.value.turns.len);
    try testing.expectEqualStrings("ping", parsed.value.turns[0].user.content);
    try testing.expectEqualStrings("pong", parsed.value.turns[0].assistant.content);
}

test "State: unknown fields are ignored on load" {
    const bytes =
        \\{
        \\  "schema_version": 1,
        \\  "id": "s1",
        \\  "turn_count": 0,
        \\  "created_at_ns": 0,
        \\  "updated_at_ns": 0,
        \\  "turns": [],
        \\  "future_field": "whatever"
        \\}
    ;
    const parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqualStrings("s1", parsed.value.id);
}
