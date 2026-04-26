//! Core SQLite handle.
//!
//! One process opens one `Db`. WAL mode for concurrent readers,
//! busy_timeout to absorb writer contention, foreign_keys ON so the
//! schema's relational invariants are enforced. Every subsystem that
//! needs persistent storage (sessions, instances, memory entries,
//! preference signals) reaches for this handle.
//!
//! Concurrency model: a single connection serialised behind `mu`.
//! SQLite is thread-safe in serialised mode, but Zig's
//! @cImport-driven binding does not surface that; the mutex makes
//! the contract explicit. Per-thread connections (one for writes,
//! many for reads) are a future optimisation if profiling demands.

const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ColumnFailed,
    OutOfMemory,
};

pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.sqlite3 = null,
    /// Borrowed; null when the database is `:memory:`.
    path: ?[]u8 = null,
    mu: std.c.pthread_mutex_t = .{},

    pub const OpenOptions = struct {
        /// Filesystem path, or `:memory:` for an ephemeral database.
        path: []const u8,
    };

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) Error!Db {
        var db: Db = .{ .allocator = allocator };

        // Null-terminate for the C API. `:memory:` is a recognised
        // sentinel; we keep it in `path` only when it's a real file
        // so deinit doesn't double-close on something that never
        // existed on disk.
        const z_path = allocator.dupeZ(u8, opts.path) catch return Error.OutOfMemory;
        defer allocator.free(z_path);

        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open(z_path.ptr, &raw) != c.SQLITE_OK) {
            if (raw) |r| _ = c.sqlite3_close(r);
            return Error.OpenFailed;
        }
        db.handle = raw;

        _ = c.sqlite3_busy_timeout(raw, 5000);

        // Pragmas that make sqlite behave the way we expect for a
        // long-running daemon. `journal_mode=WAL` is a no-op on
        // `:memory:` but the call is harmless.
        try db.exec("PRAGMA journal_mode=WAL;");
        try db.exec("PRAGMA synchronous=NORMAL;");
        try db.exec("PRAGMA foreign_keys=ON;");

        if (!std.mem.eql(u8, opts.path, ":memory:")) {
            db.path = allocator.dupe(u8, opts.path) catch {
                _ = c.sqlite3_close(raw);
                return Error.OutOfMemory;
            };
        }
        return db;
    }

    pub fn close(self: *Db) void {
        if (self.handle) |h| {
            _ = c.sqlite3_close(h);
            self.handle = null;
        }
        if (self.path) |p| {
            self.allocator.free(p);
            self.path = null;
        }
    }

    pub fn lock(self: *Db) void {
        _ = std.c.pthread_mutex_lock(&self.mu);
    }

    pub fn unlock(self: *Db) void {
        _ = std.c.pthread_mutex_unlock(&self.mu);
    }

    /// Run a single SQL statement (DDL, INSERT, UPDATE, etc.). For
    /// statements that take parameters or return rows, use
    /// `prepare` + the `Stmt` wrapper instead.
    pub fn exec(self: *Db, sql: []const u8) Error!void {
        const z = self.allocator.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.allocator.free(z);
        if (c.sqlite3_exec(self.handle, z.ptr, null, null, null) != c.SQLITE_OK) {
            return Error.ExecFailed;
        }
    }

    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        const z = self.allocator.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.allocator.free(z);
        var raw: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, z.ptr, @intCast(z.len), &raw, null) != c.SQLITE_OK) {
            return Error.PrepareFailed;
        }
        return .{ .stmt = raw, .db = self, .scratch = .empty };
    }

    /// Last inserted rowid. Only meaningful immediately after an
    /// `INSERT` on a table with an INTEGER PRIMARY KEY.
    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.handle);
    }

    /// Read `PRAGMA user_version`. Used by the migrations layer to
    /// decide which migrations have run.
    pub fn userVersion(self: *Db) Error!i64 {
        var stmt = try self.prepare("PRAGMA user_version;");
        defer stmt.deinit();
        const has_row = try stmt.step();
        if (!has_row) return 0;
        return stmt.columnInt(0);
    }

    pub fn setUserVersion(self: *Db, version: i64) Error!void {
        const sql = std.fmt.allocPrint(
            self.allocator,
            "PRAGMA user_version = {d};",
            .{version},
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(sql);
        try self.exec(sql);
    }
};

pub const Stmt = struct {
    stmt: ?*c.sqlite3_stmt,
    db: *Db,
    /// Backing storage for text binds. Sqlite is told the bytes
    /// are static (it does not own them); we keep them alive here
    /// for the statement's full lifetime, including across `step`
    /// rounds when the statement is re-bound and re-executed.
    scratch: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Stmt) void {
        if (self.stmt) |s| _ = c.sqlite3_finalize(s);
        self.stmt = null;
        self.scratch.deinit(self.db.allocator);
    }

    pub fn bindText(self: *Stmt, idx: i32, value: []const u8) Error!void {
        // We cannot cleanly construct SQLITE_TRANSIENT (the
        // `(void*)-1` sentinel) through Zig's typed @ptrFromInt
        // because the destination is a function pointer with an
        // alignment requirement that an odd integer cannot satisfy.
        // Workaround: bind with the SQLITE_STATIC destructor (null)
        // after copying into a per-statement scratch buffer that
        // outlives the prepared statement. The buffer is freed in
        // `Stmt.deinit`.
        const owned = try self.appendScratch(value);
        if (c.sqlite3_bind_text(
            self.stmt,
            idx,
            owned.ptr,
            @intCast(owned.len),
            null, // SQLITE_STATIC — bytes live until we finalize.
        ) != c.SQLITE_OK) return Error.BindFailed;
    }

    /// Append `value` to the statement's scratch buffer and return
    /// a slice that lives until `deinit`. Reused by every text
    /// bind so the prepared statement can carry its own backing
    /// storage instead of leaning on the caller's lifetime.
    fn appendScratch(self: *Stmt, value: []const u8) Error![]u8 {
        const old_len = self.scratch.items.len;
        self.scratch.appendSlice(self.db.allocator, value) catch
            return Error.OutOfMemory;
        return self.scratch.items[old_len..];
    }

    pub fn bindInt(self: *Stmt, idx: i32, value: i64) Error!void {
        if (c.sqlite3_bind_int64(self.stmt, idx, value) != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindNull(self: *Stmt, idx: i32) Error!void {
        if (c.sqlite3_bind_null(self.stmt, idx) != c.SQLITE_OK) return Error.BindFailed;
    }

    /// Advance to the next row. Returns true when a row is available
    /// (`SQLITE_ROW`); false when the statement is exhausted
    /// (`SQLITE_DONE`); errors otherwise.
    pub fn step(self: *Stmt) Error!bool {
        const rc = c.sqlite3_step(self.stmt);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => Error.StepFailed,
        };
    }

    pub fn reset(self: *Stmt) Error!void {
        if (c.sqlite3_reset(self.stmt) != c.SQLITE_OK) return Error.StepFailed;
        // Bind cache is owned by the statement; once we reset, the
        // previous binds are discarded so it is safe to drop the
        // backing bytes.
        self.scratch.clearRetainingCapacity();
    }

    pub fn columnInt(self: *Stmt, idx: i32) i64 {
        return c.sqlite3_column_int64(self.stmt, idx);
    }

    /// Borrowed slice valid until the next `step` / `reset` /
    /// `deinit`. Caller dupes if it needs to outlive that scope.
    pub fn columnText(self: *Stmt, idx: i32) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, idx) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
        return ptr[0..len];
    }

    pub fn columnIsNull(self: *Stmt, idx: i32) bool {
        return c.sqlite3_column_type(self.stmt, idx) == c.SQLITE_NULL;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Db: open in-memory and exec round-trip" {
    var db = try Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();

    try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL);");
    try db.exec("INSERT INTO t(name) VALUES('alpha');");
    try db.exec("INSERT INTO t(name) VALUES('beta');");

    var stmt = try db.prepare("SELECT id, name FROM t ORDER BY id;");
    defer stmt.deinit();

    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try testing.expectEqualStrings("alpha", stmt.columnText(1));

    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
    try testing.expectEqualStrings("beta", stmt.columnText(1));

    try testing.expect(!try stmt.step());
}

test "Db: prepared statement bind round-trip" {
    var db = try Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();

    try db.exec("CREATE TABLE kv(k TEXT PRIMARY KEY, v INTEGER NOT NULL);");

    {
        var stmt = try db.prepare("INSERT INTO kv(k, v) VALUES(?, ?);");
        defer stmt.deinit();
        try stmt.bindText(1, "answer");
        try stmt.bindInt(2, 42);
        try testing.expect(!try stmt.step());
    }
    {
        var stmt = try db.prepare("SELECT v FROM kv WHERE k = ?;");
        defer stmt.deinit();
        try stmt.bindText(1, "answer");
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 42), stmt.columnInt(0));
    }
}

test "Db: user_version read/write round-trip" {
    var db = try Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();

    try testing.expectEqual(@as(i64, 0), try db.userVersion());
    try db.setUserVersion(7);
    try testing.expectEqual(@as(i64, 7), try db.userVersion());
}
