//! memory-tigerclaw — SQLite-backed `SessionStore` for tigerclaw.
//!
//! On-disk layout under `<workspace>/.tigerclaw/memory.db`:
//!   entries(session_id, seq, ts_unix_ns, kind, body, tombstone)
//!   tags(session_id, tag)  -- UNIQUE(session_id, tag)
//!
//! Forget policies (spec v3 §4):
//!   soft  -> set tombstone=1; entries stay, future read/search skip them.
//!   scrub -> tombstone=1 AND body overwritten with zero-length blob.
//!   purge -> DELETE rows outright.
//!
//! Search is `LIKE '%text%'` on body in v0. FTS5 / vector is a later slice.
//!
//! This is the minimum viable backend — just enough to exercise the plug
//! surface end to end.

const std = @import("std");
const spec = @import("memory_spec");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Options = struct {
    /// Absolute or cwd-relative path to the workspace. The store writes
    /// to `<workspace>/.tigerclaw/memory.db`. When null, uses the
    /// process cwd.
    workspace: ?[]const u8 = null,
};

pub const InitError = error{
    OpenFailed,
    MkdirFailed,
    MigrateFailed,
    OutOfMemory,
};

/// Open (or create) a SQLite store rooted at the workspace and return a
/// `SessionStore` vtable bound to it. Caller owns `store.deinit()`.
pub fn open(allocator: std.mem.Allocator, opts: Options) InitError!spec.SessionStore {
    const workspace = opts.workspace orelse ".";
    const dir_path = try std.fs.path.joinZ(allocator, &.{ workspace, ".tigerclaw" });
    defer allocator.free(dir_path);

    // Ensure the .tigerclaw directory exists. libc mkdir is fine here —
    // SQLite will `open(2)` the db file directly in the same namespace.
    const mkdir_rc = std.c.mkdir(dir_path.ptr, 0o755);
    if (mkdir_rc != 0) {
        const e = std.c.errno(mkdir_rc);
        if (e != .EXIST) return error.MkdirFailed;
    }

    const db_path = try std.fs.path.joinZ(allocator, &.{ dir_path, "memory.db" });
    defer allocator.free(db_path);

    const impl = try allocator.create(SqliteStore);
    errdefer allocator.destroy(impl);
    impl.* = .{
        .allocator = allocator,
        .db = null,
        .search_buf = .empty,
        .list_buf = .empty,
        .str_arena = std.heap.ArenaAllocator.init(allocator),
    };

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path.ptr, &db) != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        allocator.destroy(impl);
        return error.OpenFailed;
    }
    impl.db = db;

    _ = c.sqlite3_busy_timeout(db, 5000);
    try execOrFail(db, "PRAGMA journal_mode=WAL;");
    try execOrFail(db, "PRAGMA synchronous=NORMAL;");
    try execOrFail(db, "PRAGMA foreign_keys=ON;");

    // Schema — idempotent CREATE IF NOT EXISTS.
    try execOrFail(db,
        \\CREATE TABLE IF NOT EXISTS entries (
        \\  session_id TEXT NOT NULL,
        \\  seq        INTEGER NOT NULL,
        \\  ts_unix_ns INTEGER NOT NULL,
        \\  kind       INTEGER NOT NULL,
        \\  body       BLOB NOT NULL,
        \\  tombstone  INTEGER NOT NULL DEFAULT 0,
        \\  PRIMARY KEY(session_id, seq)
        \\);
    );
    try execOrFail(db,
        \\CREATE TABLE IF NOT EXISTS tags (
        \\  session_id TEXT NOT NULL,
        \\  tag        TEXT NOT NULL,
        \\  UNIQUE(session_id, tag)
        \\);
    );
    try execOrFail(db,
        \\CREATE INDEX IF NOT EXISTS idx_entries_live
        \\  ON entries(session_id, seq) WHERE tombstone=0;
    );

    return .{ .ptr = impl, .vtable = &vtable };
}

// --- implementation --------------------------------------------------------

const SqliteStore = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    // Reusable buffer the vtable uses to own string slices it returns to
    // callers in `read`/`search`/`list_sessions`. Valid until the next
    // mutating call on the same op.
    search_buf: std.ArrayList(u8),
    list_buf: std.ArrayList(u8),
    str_arena: std.heap.ArenaAllocator,

    fn cast(ptr: *anyopaque) *SqliteStore {
        return @ptrCast(@alignCast(ptr));
    }
};

const vtable: spec.SessionStore.VTable = .{
    .append = appendFn,
    .read = readFn,
    .search = searchFn,
    .list_sessions = listSessionsFn,
    .tag = tagFn,
    .forget = forgetFn,
    .deinit = deinitFn,
};

fn validateSession(session_id: spec.SessionId) bool {
    if (session_id.len == 0 or session_id.len > 512) return false;
    for (session_id) |ch| if (ch == 0) return false;
    return true;
}

fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    const sec_ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s;
    const nsec: i128 = @intCast(ts.nsec);
    return sec_ns + nsec;
}

fn appendFn(ptr: *anyopaque, session_id: spec.SessionId, entry: spec.Entry) spec.AppendError!spec.Seq {
    const self = SqliteStore.cast(ptr);
    if (!validateSession(session_id)) return error.InvalidSession;

    // next seq = COALESCE(MAX(seq), 0) + 1 for this session.
    var next_seq: spec.Seq = 1;
    {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT COALESCE(MAX(seq), 0) FROM entries WHERE session_id = ?;";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.BackendFailure;
        const max_seq: i64 = c.sqlite3_column_int64(stmt, 0);
        next_seq = @intCast(max_seq + 1);
    }

    const ts: i64 = @intCast(if (entry.ts_unix_ns != 0) entry.ts_unix_ns else nowNs());

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO entries(session_id, seq, ts_unix_ns, kind, body, tombstone) VALUES(?,?,?,?,?,0);";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(next_seq));
    _ = c.sqlite3_bind_int64(stmt, 3, ts);
    _ = c.sqlite3_bind_int(stmt, 4, @intFromEnum(entry.kind));
    _ = c.sqlite3_bind_blob(stmt, 5, entry.body.ptr, @intCast(entry.body.len), c.SQLITE_STATIC);

    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_FULL) return error.CapacityExceeded;
    if (rc != c.SQLITE_DONE) return error.BackendFailure;
    return next_seq;
}

fn resetStringArena(self: *SqliteStore) void {
    _ = self.str_arena.reset(.retain_capacity);
}

fn dupFromDb(self: *SqliteStore, bytes: []const u8) spec.ReadError![]u8 {
    const allocator = self.str_arena.allocator();
    const out = allocator.alloc(u8, bytes.len) catch return error.BackendFailure;
    @memcpy(out, bytes);
    return out;
}

fn readFn(
    ptr: *anyopaque,
    session_id: spec.SessionId,
    range: spec.Range,
    buf: []spec.Entry,
) spec.ReadError!usize {
    const self = SqliteStore.cast(ptr);
    if (!validateSession(session_id)) return error.InvalidSession;
    if (buf.len == 0) return 0;

    resetStringArena(self);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT seq, ts_unix_ns, kind, body FROM entries WHERE session_id=? AND seq>=? AND tombstone=0 ORDER BY seq ASC LIMIT ?;";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(range.from_seq));
    const lim: i64 = if (range.limit == 0) @intCast(buf.len) else @intCast(@min(range.limit, buf.len));
    _ = c.sqlite3_bind_int64(stmt, 3, lim);

    var i: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW and i < buf.len) : (i += 1) {
        const seq: i64 = c.sqlite3_column_int64(stmt, 0);
        const ts: i64 = c.sqlite3_column_int64(stmt, 1);
        const kind_raw: c_int = c.sqlite3_column_int(stmt, 2);
        const body_ptr = c.sqlite3_column_blob(stmt, 3);
        const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        const body_src = if (body_ptr) |p| @as([*]const u8, @ptrCast(p))[0..body_len] else &[_]u8{};
        const body_dup = try dupFromDb(self, body_src);

        buf[i] = .{
            .seq = @intCast(seq),
            .ts_unix_ns = @intCast(ts),
            .kind = @enumFromInt(@as(u8, @intCast(kind_raw))),
            .body = body_dup,
        };
    }
    return i;
}

fn searchFn(
    ptr: *anyopaque,
    session_id: spec.SessionId,
    query: spec.Query,
    buf: []spec.Entry,
) spec.SearchError!usize {
    const self = SqliteStore.cast(ptr);
    if (!validateSession(session_id)) return error.InvalidSession;
    if (buf.len == 0) return 0;

    resetStringArena(self);

    // Build LIKE pattern in the arena so the memory stays alive for the step loop.
    const arena_alloc = self.str_arena.allocator();
    const pattern = std.fmt.allocPrint(arena_alloc, "%{s}%", .{query.text}) catch return error.BackendFailure;

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT seq, ts_unix_ns, kind, body FROM entries WHERE session_id=? AND tombstone=0 AND body LIKE ? ORDER BY seq ASC LIMIT ?;";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, pattern.ptr, @intCast(pattern.len), c.SQLITE_STATIC);
    const lim: i64 = @intCast(@min(if (query.limit == 0) buf.len else query.limit, buf.len));
    _ = c.sqlite3_bind_int64(stmt, 3, lim);

    var i: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW and i < buf.len) : (i += 1) {
        const seq: i64 = c.sqlite3_column_int64(stmt, 0);
        const ts: i64 = c.sqlite3_column_int64(stmt, 1);
        const kind_raw: c_int = c.sqlite3_column_int(stmt, 2);
        const body_ptr = c.sqlite3_column_blob(stmt, 3);
        const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        const body_src = if (body_ptr) |p| @as([*]const u8, @ptrCast(p))[0..body_len] else &[_]u8{};
        const body_dup = arena_alloc.alloc(u8, body_src.len) catch return error.BackendFailure;
        @memcpy(body_dup, body_src);

        buf[i] = .{
            .seq = @intCast(seq),
            .ts_unix_ns = @intCast(ts),
            .kind = @enumFromInt(@as(u8, @intCast(kind_raw))),
            .body = body_dup,
        };
    }
    return i;
}

fn listSessionsFn(ptr: *anyopaque, buf: []spec.SessionId) spec.ListError!usize {
    const self = SqliteStore.cast(ptr);
    if (buf.len == 0) return 0;

    resetStringArena(self);
    const arena_alloc = self.str_arena.allocator();

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT DISTINCT session_id FROM entries ORDER BY session_id ASC LIMIT ?;";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(buf.len));

    var i: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW and i < buf.len) : (i += 1) {
        const txt_ptr = c.sqlite3_column_text(stmt, 0);
        const txt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const src = if (txt_ptr) |p| @as([*]const u8, @ptrCast(p))[0..txt_len] else &[_]u8{};
        const dup = arena_alloc.alloc(u8, src.len) catch return error.BackendFailure;
        @memcpy(dup, src);
        buf[i] = dup;
    }
    return i;
}

fn tagFn(ptr: *anyopaque, session_id: spec.SessionId, t: spec.Tag) spec.TagError!void {
    const self = SqliteStore.cast(ptr);
    if (!validateSession(session_id)) return error.InvalidSession;

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT OR IGNORE INTO tags(session_id, tag) VALUES(?, ?);";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, t.ptr, @intCast(t.len), c.SQLITE_STATIC);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.BackendFailure;
}

fn forgetFn(ptr: *anyopaque, session_id: spec.SessionId, policy: spec.ForgetPolicy) spec.ForgetError!void {
    const self = SqliteStore.cast(ptr);
    if (!validateSession(session_id)) return error.InvalidSession;

    const sql: [*:0]const u8 = switch (policy) {
        .soft => "UPDATE entries SET tombstone=1 WHERE session_id=?;",
        .scrub => "UPDATE entries SET tombstone=1, body=X'' WHERE session_id=?;",
        .purge => "DELETE FROM entries WHERE session_id=?;",
    };

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.BackendFailure;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.BackendFailure;

    if (policy == .purge) {
        var del_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM tags WHERE session_id=?;", -1, &del_stmt, null) != c.SQLITE_OK) return error.BackendFailure;
        defer _ = c.sqlite3_finalize(del_stmt);
        _ = c.sqlite3_bind_text(del_stmt, 1, session_id.ptr, @intCast(session_id.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(del_stmt) != c.SQLITE_DONE) return error.BackendFailure;
    }
}

fn deinitFn(ptr: *anyopaque) void {
    const self = SqliteStore.cast(ptr);
    if (self.db) |d| _ = c.sqlite3_close(d);
    self.str_arena.deinit();
    self.search_buf.deinit(self.allocator);
    self.list_buf.deinit(self.allocator);
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn execOrFail(db: ?*c.sqlite3, sql: [*:0]const u8) InitError!void {
    var err: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql, null, null, &err);
    if (rc != c.SQLITE_OK) {
        if (err != null) c.sqlite3_free(err);
        return error.MigrateFailed;
    }
}

// --- tests -----------------------------------------------------------------

/// Build a unique absolute workspace path under /tmp and create it.
/// Cleanup is best-effort and left to the OS — the store `open()` call
/// will mkdir `.tigerclaw/` inside it. Caller frees the returned slice.
fn makeTestWorkspace(allocator: std.mem.Allocator) ![]u8 {
    const now: u64 = @bitCast(@as(i64, @truncate(nowNs())));
    var prng = std.Random.DefaultPrng.init(now);
    var seed: [8]u8 = undefined;
    prng.random().bytes(&seed);
    const name = std.fmt.bytesToHex(seed, .lower);

    // Plain allocPrint returns []u8 with no embedded NUL. We need a
    // 0-terminated copy for std.c.mkdir, so stage into a local buffer.
    const workspace = try std.fmt.allocPrint(allocator, "/tmp/tc-mem-{s}", .{name});
    errdefer allocator.free(workspace);

    var z_buf: [256]u8 = undefined;
    if (workspace.len >= z_buf.len) return error.PathTooLong;
    @memcpy(z_buf[0..workspace.len], workspace);
    z_buf[workspace.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&z_buf);

    if (std.c.mkdir(path_z, 0o755) != 0) return error.MkdirFailed;
    return workspace;
}

test "open + append + read round-trip" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    const seq1 = try store.append("sess-a", .{ .kind = .user, .body = "hello world" });
    const seq2 = try store.append("sess-a", .{ .kind = .assistant, .body = "hi there" });
    try std.testing.expectEqual(@as(spec.Seq, 1), seq1);
    try std.testing.expectEqual(@as(spec.Seq, 2), seq2);

    var buf: [8]spec.Entry = undefined;
    const got = try store.read("sess-a", .{}, &buf);
    try std.testing.expectEqual(@as(usize, 2), got);
    try std.testing.expectEqualStrings("hello world", buf[0].body);
    try std.testing.expectEqual(spec.Entry.Kind.assistant, buf[1].kind);
}

test "search finds substring in body" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    _ = try store.append("s", .{ .kind = .user, .body = "the quick brown fox" });
    _ = try store.append("s", .{ .kind = .assistant, .body = "jumps over the lazy dog" });

    var buf: [4]spec.Entry = undefined;
    const got = try store.search("s", .{ .text = "fox" }, &buf);
    try std.testing.expectEqual(@as(usize, 1), got);
    try std.testing.expectEqualStrings("the quick brown fox", buf[0].body);
}

test "listSessions enumerates distinct session ids" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    _ = try store.append("alpha", .{ .kind = .user, .body = "x" });
    _ = try store.append("beta", .{ .kind = .user, .body = "y" });
    _ = try store.append("alpha", .{ .kind = .user, .body = "z" });

    var buf: [8]spec.SessionId = undefined;
    const n = try store.listSessions(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("alpha", buf[0]);
    try std.testing.expectEqualStrings("beta", buf[1]);
}

test "tag is idempotent" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    _ = try store.append("s", .{ .kind = .user, .body = "x" });
    try store.tag("s", "important");
    try store.tag("s", "important"); // same tag, no error
    try store.tag("s", "starred");
}

test "forget.soft hides entries from read; purge removes them" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    _ = try store.append("s", .{ .kind = .user, .body = "one" });
    _ = try store.append("s", .{ .kind = .user, .body = "two" });

    try store.forget("s", .soft);
    var buf: [4]spec.Entry = undefined;
    try std.testing.expectEqual(@as(usize, 0), try store.read("s", .{}, &buf));

    try store.forget("s", .purge);
    var slist: [4]spec.SessionId = undefined;
    try std.testing.expectEqual(@as(usize, 0), try store.listSessions(&slist));
}

test "invalid session id rejected" {
    const allocator = std.testing.allocator;
    const workspace = try makeTestWorkspace(allocator);
    defer allocator.free(workspace);

    const store = try open(allocator, .{ .workspace = workspace });
    defer store.deinit();

    try std.testing.expectError(error.InvalidSession, store.append("", .{ .kind = .user, .body = "x" }));
}
