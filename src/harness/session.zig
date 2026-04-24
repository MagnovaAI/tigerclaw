//! A running conversation.
//!
//! `Session` is the mutable, in-memory owner of one conversation. It
//! holds:
//!   * the persistent `State` snapshot that will be written to disk,
//!   * a growing list of `Turn`s captured during the lifetime of the
//!     process, and
//!   * the heap-allocated strings backing every user/assistant message.
//!
//! Lifecycle:
//!   1. `Session.start(...)` creates a fresh session with a new id and
//!      stamps `created_at_ns`.
//!   2. `Session.resumeFromBytes(...)` rehydrates an existing session
//!      from a JSON blob — the core of the `--resume` flag.
//!   3. `appendTurn(...)` commits one completed user→assistant pair.
//!   4. `save(...)` writes the current `State` atomically via the
//!      shared `settings.internal_writes.writeAtomic` helper (write to
//!      a tmp sibling, fsync, rename).
//!   5. `deinit()` frees every owned allocation.
//!
//! Strings added via `appendTurn` are duplicated into the session
//! allocator so the caller's buffers can be freed independently. The
//! session owns its own memory, full stop.

const std = @import("std");
const Io = std.Io;
const types = @import("types");
const clock_mod = @import("clock");
const internal_writes = @import("../settings/internal_writes.zig");
const state_mod = @import("state.zig");
const turn_mod = @import("turn.zig");

pub const State = state_mod.State;
pub const Turn = turn_mod.Turn;

/// Errors specific to session resume. File-system and JSON parse
/// errors surface directly from the standard library; we only add one
/// semantic code of our own.
pub const ResumeError = error{
    /// The loaded file's `schema_version` does not match what this
    /// binary writes. Older files require migration; newer files mean
    /// the operator is running a downgraded binary. Either way we
    /// refuse rather than silently reinterpret the layout. Callers
    /// should surface `state_mod.migrationHint()` to the user.
    UnsupportedSchemaVersion,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    /// Growing list of committed turns. Indices match `Turn.index`.
    turns: std.ArrayList(Turn),
    /// Owned copy of the session id. Lives for the lifetime of the
    /// session so handing it out as `[]const u8` is safe until
    /// `deinit` runs.
    id_owned: []u8,
    created_at_ns: i128,
    updated_at_ns: i128,

    /// Start a brand-new session. `session_id` is copied.
    pub fn start(
        allocator: std.mem.Allocator,
        clock: clock_mod.Clock,
        session_id: []const u8,
    ) !Session {
        const now = clock.nowNs();
        const id_copy = try allocator.dupe(u8, session_id);
        return .{
            .allocator = allocator,
            .clock = clock,
            .turns = .empty,
            .id_owned = id_copy,
            .created_at_ns = now,
            .updated_at_ns = now,
        };
    }

    /// Rehydrate a session from JSON bytes produced by `save`. Strings
    /// inside the transient parse arena are copied into the session
    /// allocator so `bytes` can be dropped immediately on return.
    pub fn resumeFromBytes(
        allocator: std.mem.Allocator,
        clock: clock_mod.Clock,
        bytes: []const u8,
    ) !Session {
        var parsed = try state_mod.parse(allocator, bytes);
        defer parsed.deinit();

        if (parsed.value.schema_version != state_mod.schema_version) {
            return ResumeError.UnsupportedSchemaVersion;
        }

        var session = Session{
            .allocator = allocator,
            .clock = clock,
            .turns = .empty,
            .id_owned = try allocator.dupe(u8, parsed.value.id),
            .created_at_ns = parsed.value.created_at_ns,
            .updated_at_ns = parsed.value.updated_at_ns,
        };
        errdefer session.deinit();

        try session.turns.ensureTotalCapacity(allocator, parsed.value.turns.len);
        for (parsed.value.turns) |t| {
            const user_copy = try allocator.dupe(u8, t.user.content);
            errdefer allocator.free(user_copy);
            const assistant_copy = try allocator.dupe(u8, t.assistant.content);
            errdefer allocator.free(assistant_copy);
            try session.turns.append(allocator, .{
                .index = t.index,
                .started_at_ns = t.started_at_ns,
                .finished_at_ns = t.finished_at_ns,
                .user = .{ .role = t.user.role, .content = user_copy },
                .assistant = .{ .role = t.assistant.role, .content = assistant_copy },
            });
        }
        return session;
    }

    pub fn deinit(self: *Session) void {
        for (self.turns.items) |t| {
            self.allocator.free(t.user.content);
            self.allocator.free(t.assistant.content);
        }
        self.turns.deinit(self.allocator);
        self.allocator.free(self.id_owned);
        self.* = undefined;
    }

    pub fn id(self: *const Session) []const u8 {
        return self.id_owned;
    }

    pub fn turnCount(self: *const Session) u32 {
        return @intCast(self.turns.items.len);
    }

    /// Commit one user→assistant pair. Contents are copied — caller
    /// retains ownership of the inputs.
    pub fn appendTurn(
        self: *Session,
        user_content: []const u8,
        assistant_content: []const u8,
    ) !void {
        const now = self.clock.nowNs();
        // Both endpoints are stamped at `now`; finer-grained timing
        // arrives with the react loop in a later commit. Tests observe
        // ordering by advancing the `ManualClock` between calls.
        const started = now;
        const finished = now;

        const user_copy = try self.allocator.dupe(u8, user_content);
        errdefer self.allocator.free(user_copy);
        const assistant_copy = try self.allocator.dupe(u8, assistant_content);
        errdefer self.allocator.free(assistant_copy);

        try self.turns.append(self.allocator, .{
            .index = self.turnCount(),
            .started_at_ns = started,
            .finished_at_ns = finished,
            .user = .{ .role = .user, .content = user_copy },
            .assistant = .{ .role = .assistant, .content = assistant_copy },
        });
        self.updated_at_ns = now;
    }

    /// Build a transient `State` view over the session's live turns.
    /// The returned value aliases the session's internal slices — do
    /// NOT use it after mutating the session. It is intended to be
    /// handed straight to `state.stringify` / `state.writeJson`.
    pub fn snapshot(self: *const Session) State {
        return .{
            .id = self.id_owned,
            .turn_count = self.turnCount(),
            .created_at_ns = self.created_at_ns,
            .updated_at_ns = self.updated_at_ns,
            .turns = self.turns.items,
        };
    }

    /// Serialise the current snapshot to a caller-owned byte slice.
    pub fn toJson(self: *const Session) ![]u8 {
        return state_mod.stringify(self.allocator, self.snapshot());
    }

    /// Atomically persist the session to `sub_path` under `dir`.
    /// Delegates to the shared `writeAtomic` helper so every on-disk
    /// write in the runtime goes through the same tmp-rename path.
    pub fn save(
        self: *const Session,
        dir: Io.Dir,
        io: Io,
        sub_path: []const u8,
    ) !void {
        const bytes = try self.toJson();
        defer self.allocator.free(bytes);
        try internal_writes.writeAtomic(dir, io, sub_path, bytes);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Session: start stamps created_at from the clock" {
    var mc = clock_mod.ManualClock{ .value_ns = 1_000 };
    var s = try Session.start(testing.allocator, mc.clock(), "s-1");
    defer s.deinit();

    try testing.expectEqualStrings("s-1", s.id());
    try testing.expectEqual(@as(u32, 0), s.turnCount());
    try testing.expectEqual(@as(i128, 1_000), s.created_at_ns);
    try testing.expectEqual(@as(i128, 1_000), s.updated_at_ns);
}

test "Session: appendTurn copies content and advances indexes" {
    var mc = clock_mod.ManualClock{ .value_ns = 10 };
    var s = try Session.start(testing.allocator, mc.clock(), "s-1");
    defer s.deinit();

    try s.appendTurn("hi", "hello");
    mc.advance(5);
    try s.appendTurn("again", "still here");

    try testing.expectEqual(@as(u32, 2), s.turnCount());
    try testing.expectEqual(@as(u32, 0), s.turns.items[0].index);
    try testing.expectEqual(@as(u32, 1), s.turns.items[1].index);
    try testing.expectEqualStrings("hi", s.turns.items[0].user.content);
    try testing.expectEqualStrings("still here", s.turns.items[1].assistant.content);
    try testing.expectEqual(@as(i128, 15), s.updated_at_ns);
}

test "Session: resumeFromBytes rehydrates prior turns" {
    var mc = clock_mod.ManualClock{ .value_ns = 100 };
    var original = try Session.start(testing.allocator, mc.clock(), "sess-42");
    defer original.deinit();
    try original.appendTurn("q1", "a1");
    mc.advance(10);
    try original.appendTurn("q2", "a2");

    const bytes = try original.toJson();
    defer testing.allocator.free(bytes);

    var mc2 = clock_mod.ManualClock{ .value_ns = 999 };
    var resumed = try Session.resumeFromBytes(testing.allocator, mc2.clock(), bytes);
    defer resumed.deinit();

    try testing.expectEqualStrings("sess-42", resumed.id());
    try testing.expectEqual(@as(u32, 2), resumed.turnCount());
    try testing.expectEqualStrings("q1", resumed.turns.items[0].user.content);
    try testing.expectEqualStrings("a2", resumed.turns.items[1].assistant.content);
    try testing.expectEqual(original.created_at_ns, resumed.created_at_ns);
}

test "Session: resumeFromBytes rejects newer schema versions" {
    const bytes =
        \\{"schema_version":9999,"id":"x","turn_count":0,"created_at_ns":0,"updated_at_ns":0,"turns":[]}
    ;
    var mc = clock_mod.ManualClock{};
    try testing.expectError(
        ResumeError.UnsupportedSchemaVersion,
        Session.resumeFromBytes(testing.allocator, mc.clock(), bytes),
    );
}

test "Session: save writes an atomic JSON file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 7 };
    var s = try Session.start(testing.allocator, mc.clock(), "on-disk");
    defer s.deinit();
    try s.appendTurn("u", "a");

    try s.save(tmp.dir, testing.io, "session.json");

    var buf: [8 * 1024]u8 = undefined;
    const read_bytes = try tmp.dir.readFile(testing.io, "session.json", &buf);

    var resumed = try Session.resumeFromBytes(testing.allocator, mc.clock(), read_bytes);
    defer resumed.deinit();
    try testing.expectEqualStrings("on-disk", resumed.id());
    try testing.expectEqual(@as(u32, 1), resumed.turnCount());
}
