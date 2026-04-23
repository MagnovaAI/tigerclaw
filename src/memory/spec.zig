//! Session-store abstraction: the vtable, value types, and errors every
//! memory backend (in-memory, SQLite, Postgres, LanceDB, …) must implement
//! so the `remember` verb can treat them uniformly.
//!
//! The vtable mirrors the `session_store` plugger defined in
//! `docs/spec/agent-architecture-v3.yaml` §4. The verb contract says
//! `remember` is called at least three times per turn (turn start, once
//! per tool result, once at end), so the surface is deliberately small
//! and allocation-free on the read paths.
//!
//! Concurrency contract:
//!   * The vtable methods may be invoked from any thread.
//!   * A single `SessionStore` value does NOT need to serialise its own
//!     callers — the runtime holds at most one in-flight call per
//!     `(session_id, vtable)` pair today. Backends that want broader
//!     safety declare it in their manifest.

const std = @import("std");

/// Session identifier. Borrowed by the caller; the store copies what it
/// needs before returning. URL-safe text, no embedded NUL.
pub const SessionId = []const u8;

/// Monotonic sequence number assigned by the store on `append`. Callers
/// treat it as an opaque cursor — only equality and ordering are defined.
pub const Seq = u64;

/// Optional tag a session can be labelled with. Multiple tags per session
/// are allowed; the store deduplicates.
pub const Tag = []const u8;

/// A single turn fragment: user input, model output, tool call, tool
/// result, or system note. The store preserves insertion order within a
/// session and assigns each entry a `seq` on write.
pub const Entry = struct {
    /// Assigned by the store on `append`; ignored on input.
    seq: Seq = 0,
    /// Wall-clock time of the write, Unix nanoseconds. The store MAY
    /// overwrite this with its own clock when strictly monotonic
    /// ordering is required.
    ts_unix_ns: i128 = 0,
    kind: Kind,
    /// Raw payload. For text-like kinds this is UTF-8; for tool results
    /// the shape is opaque. Borrowed on write, copied by the store.
    body: []const u8,

    pub const Kind = enum(u8) {
        user,
        assistant,
        tool_call,
        tool_result,
        system,
    };
};

/// Range selector for `read`. `from_seq` is inclusive. `limit == 0` means
/// "no limit" — backends MAY still cap for memory safety.
pub const Range = struct {
    from_seq: Seq = 0,
    limit: usize = 0,
};

/// Query for `search`. The store decides which retrieval strategy
/// (keyword, vector, recency) to apply; the spec treats them all as
/// sub-features of the same plug per v3 §1 remember.note.
pub const Query = struct {
    text: []const u8,
    limit: usize = 16,
};

/// Forget policies, verbatim from spec §4 session_store.forget_policy.
pub const ForgetPolicy = enum {
    /// Mark deleted; readable by attest only.
    soft,
    /// Overwrite PII fields in place; retain shape.
    scrub,
    /// Hard delete; attest retains hash-only record.
    purge,
};

pub const AppendError = error{
    /// Session identifier failed validation (empty, too long, NUL, …).
    InvalidSession,
    /// Store is full or quota exhausted.
    CapacityExceeded,
    /// Underlying backend failed (disk, network, …). Caller decides
    /// whether to retry.
    BackendFailure,
};

pub const ReadError = error{
    InvalidSession,
    BackendFailure,
};

pub const SearchError = error{
    InvalidSession,
    BackendFailure,
};

pub const ListError = error{
    BackendFailure,
};

pub const TagError = error{
    InvalidSession,
    BackendFailure,
};

pub const ForgetError = error{
    InvalidSession,
    BackendFailure,
};

pub const SessionStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Append one entry. The store assigns `seq` and (optionally)
        /// `ts_unix_ns`, and returns the assigned `seq` so callers can
        /// pin later reads against a known cursor.
        append: *const fn (
            ptr: *anyopaque,
            session_id: SessionId,
            entry: Entry,
        ) AppendError!Seq,

        /// Read entries in order. Caller-allocated `buf` is filled in
        /// ascending `seq`; returns the count actually populated. A zero
        /// return means the session is empty or the range is past the
        /// end. Entry bodies reference store-owned memory valid until
        /// the next mutating call on the same session.
        read: *const fn (
            ptr: *anyopaque,
            session_id: SessionId,
            range: Range,
            buf: []Entry,
        ) ReadError!usize,

        /// Search within a session. Same buffer-fill contract as `read`.
        search: *const fn (
            ptr: *anyopaque,
            session_id: SessionId,
            query: Query,
            buf: []Entry,
        ) SearchError!usize,

        /// Enumerate session ids the store knows about. The slice is
        /// store-owned and valid until the next mutating call.
        list_sessions: *const fn (
            ptr: *anyopaque,
            buf: []SessionId,
        ) ListError!usize,

        /// Attach a tag to a session. Idempotent — tagging the same
        /// session with the same tag twice is not an error.
        tag: *const fn (
            ptr: *anyopaque,
            session_id: SessionId,
            t: Tag,
        ) TagError!void,

        /// Apply a forget policy to a session. Semantics per
        /// `ForgetPolicy`. Safe to call on an unknown session — returns
        /// without error.
        forget: *const fn (
            ptr: *anyopaque,
            session_id: SessionId,
            policy: ForgetPolicy,
        ) ForgetError!void,

        /// Release backend resources (file handles, connections).
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn append(self: SessionStore, session_id: SessionId, entry: Entry) AppendError!Seq {
        return self.vtable.append(self.ptr, session_id, entry);
    }

    pub fn read(
        self: SessionStore,
        session_id: SessionId,
        range: Range,
        buf: []Entry,
    ) ReadError!usize {
        return self.vtable.read(self.ptr, session_id, range, buf);
    }

    pub fn search(
        self: SessionStore,
        session_id: SessionId,
        query: Query,
        buf: []Entry,
    ) SearchError!usize {
        return self.vtable.search(self.ptr, session_id, query, buf);
    }

    pub fn listSessions(self: SessionStore, buf: []SessionId) ListError!usize {
        return self.vtable.list_sessions(self.ptr, buf);
    }

    pub fn tag(self: SessionStore, session_id: SessionId, t: Tag) TagError!void {
        return self.vtable.tag(self.ptr, session_id, t);
    }

    pub fn forget(
        self: SessionStore,
        session_id: SessionId,
        policy: ForgetPolicy,
    ) ForgetError!void {
        return self.vtable.forget(self.ptr, session_id, policy);
    }

    pub fn deinit(self: SessionStore) void {
        self.vtable.deinit(self.ptr);
    }
};

// --- tests -----------------------------------------------------------------

const FakeStore = struct {
    append_calls: usize = 0,
    read_calls: usize = 0,
    search_calls: usize = 0,
    list_calls: usize = 0,
    tag_calls: usize = 0,
    forget_calls: usize = 0,
    deinit_calls: usize = 0,
    last_session: ?SessionId = null,
    last_entry: ?Entry = null,
    last_policy: ?ForgetPolicy = null,
    last_tag: ?Tag = null,
    next_seq: Seq = 1,
    fail_append: bool = false,
    canned_read: []const Entry = &.{},
    canned_sessions: []const SessionId = &.{},

    fn store(self: *FakeStore) SessionStore {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn appendFn(ptr: *anyopaque, session_id: SessionId, entry: Entry) AppendError!Seq {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.append_calls += 1;
        self.last_session = session_id;
        self.last_entry = entry;
        if (self.fail_append) return AppendError.CapacityExceeded;
        const s = self.next_seq;
        self.next_seq += 1;
        return s;
    }

    fn readFn(
        ptr: *anyopaque,
        session_id: SessionId,
        range: Range,
        buf: []Entry,
    ) ReadError!usize {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.read_calls += 1;
        self.last_session = session_id;
        _ = range;
        const n = @min(buf.len, self.canned_read.len);
        for (0..n) |i| buf[i] = self.canned_read[i];
        return n;
    }

    fn searchFn(
        ptr: *anyopaque,
        session_id: SessionId,
        query: Query,
        buf: []Entry,
    ) SearchError!usize {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.search_calls += 1;
        self.last_session = session_id;
        _ = query;
        const n = @min(buf.len, self.canned_read.len);
        for (0..n) |i| buf[i] = self.canned_read[i];
        return n;
    }

    fn listSessionsFn(ptr: *anyopaque, buf: []SessionId) ListError!usize {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.list_calls += 1;
        const n = @min(buf.len, self.canned_sessions.len);
        for (0..n) |i| buf[i] = self.canned_sessions[i];
        return n;
    }

    fn tagFn(ptr: *anyopaque, session_id: SessionId, t: Tag) TagError!void {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.tag_calls += 1;
        self.last_session = session_id;
        self.last_tag = t;
    }

    fn forgetFn(
        ptr: *anyopaque,
        session_id: SessionId,
        policy: ForgetPolicy,
    ) ForgetError!void {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.forget_calls += 1;
        self.last_session = session_id;
        self.last_policy = policy;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.deinit_calls += 1;
    }

    const vt: SessionStore.VTable = .{
        .append = appendFn,
        .read = readFn,
        .search = searchFn,
        .list_sessions = listSessionsFn,
        .tag = tagFn,
        .forget = forgetFn,
        .deinit = deinitFn,
    };
};

test "SessionStore.append forwards payload and returns assigned seq" {
    var fake: FakeStore = .{};
    const s = fake.store();
    const seq = try s.append("sess-1", .{ .kind = .user, .body = "hello" });
    try std.testing.expectEqual(@as(Seq, 1), seq);
    try std.testing.expectEqual(@as(usize, 1), fake.append_calls);
    try std.testing.expectEqualStrings("sess-1", fake.last_session.?);
    try std.testing.expectEqual(Entry.Kind.user, fake.last_entry.?.kind);
    try std.testing.expectEqualStrings("hello", fake.last_entry.?.body);
}

test "SessionStore.append propagates CapacityExceeded" {
    var fake: FakeStore = .{ .fail_append = true };
    const s = fake.store();
    try std.testing.expectError(
        AppendError.CapacityExceeded,
        s.append("sess-1", .{ .kind = .user, .body = "x" }),
    );
}

test "SessionStore.read fills buf in order and returns count" {
    const entries = [_]Entry{
        .{ .seq = 1, .kind = .user, .body = "a" },
        .{ .seq = 2, .kind = .assistant, .body = "b" },
    };
    var fake: FakeStore = .{ .canned_read = &entries };
    const s = fake.store();

    var buf: [4]Entry = undefined;
    const got = try s.read("sess-1", .{}, &buf);
    try std.testing.expectEqual(@as(usize, 2), got);
    try std.testing.expectEqual(@as(Seq, 1), buf[0].seq);
    try std.testing.expectEqual(Entry.Kind.assistant, buf[1].kind);
}

test "SessionStore.search forwards query" {
    const entries = [_]Entry{.{ .seq = 3, .kind = .tool_result, .body = "match" }};
    var fake: FakeStore = .{ .canned_read = &entries };
    const s = fake.store();

    var buf: [1]Entry = undefined;
    const got = try s.search("sess-1", .{ .text = "match" }, &buf);
    try std.testing.expectEqual(@as(usize, 1), got);
    try std.testing.expectEqual(@as(usize, 1), fake.search_calls);
}

test "SessionStore.listSessions enumerates ids" {
    const ids = [_]SessionId{ "a", "b", "c" };
    var fake: FakeStore = .{ .canned_sessions = &ids };
    const s = fake.store();

    var buf: [8]SessionId = undefined;
    const got = try s.listSessions(&buf);
    try std.testing.expectEqual(@as(usize, 3), got);
    try std.testing.expectEqualStrings("b", buf[1]);
}

test "SessionStore.tag records session and tag" {
    var fake: FakeStore = .{};
    const s = fake.store();
    try s.tag("sess-1", "important");
    try std.testing.expectEqual(@as(usize, 1), fake.tag_calls);
    try std.testing.expectEqualStrings("important", fake.last_tag.?);
}

test "SessionStore.forget threads each policy through" {
    var fake: FakeStore = .{};
    const s = fake.store();
    try s.forget("sess-1", .soft);
    try s.forget("sess-1", .scrub);
    try s.forget("sess-1", .purge);
    try std.testing.expectEqual(@as(usize, 3), fake.forget_calls);
    try std.testing.expectEqual(ForgetPolicy.purge, fake.last_policy.?);
}

test "SessionStore.deinit is invoked exactly once" {
    var fake: FakeStore = .{};
    const s = fake.store();
    s.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.deinit_calls);
}
