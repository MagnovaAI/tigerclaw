//! Schema migrations.
//!
//! SQLite's `PRAGMA user_version` is the source of truth for which
//! migrations have run. The list below is append-only: never edit
//! a past entry, never reorder. New schema lands as a new entry at
//! the end and bumps the version by 1 on first daemon start.

const std = @import("std");
const sqlite = @import("sqlite.zig");

const log = std.log.scoped(.db_migrate);

/// Each migration is one or more SQL statements run in a single
/// transaction. The runner halts on the first failure so a partial
/// schema cannot corrupt downstream code.
pub const Migration = struct {
    name: []const u8,
    sql: []const u8,
};

/// Append-only list. Insert at the end; bump nothing else.
pub const all_migrations = [_]Migration{
    .{
        .name = "0001_sessions_and_turns",
        .sql =
        \\CREATE TABLE sessions(
        \\  id          TEXT    PRIMARY KEY,
        \\  agent_id    TEXT    NOT NULL,
        \\  channel_id  TEXT    NOT NULL,
        \\  created_at_ns BIGINT NOT NULL,
        \\  updated_at_ns BIGINT NOT NULL
        \\);
        \\CREATE INDEX idx_sessions_agent ON sessions(agent_id);
        \\
        \\CREATE TABLE turns(
        \\  session_id  TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        \\  idx         INTEGER NOT NULL,
        \\  user_text   TEXT    NOT NULL,
        \\  asst_text   TEXT    NOT NULL,
        \\  ts_ns       BIGINT  NOT NULL,
        \\  PRIMARY KEY(session_id, idx)
        \\);
        ,
    },
    .{
        .name = "0002_memory_entries",
        .sql =
        \\CREATE TABLE memory_entries(
        \\  session_id  TEXT    NOT NULL,
        \\  seq         INTEGER NOT NULL,
        \\  ts_ns       BIGINT  NOT NULL,
        \\  kind        TEXT    NOT NULL,
        \\  body        BLOB    NOT NULL,
        \\  tombstone   INTEGER NOT NULL DEFAULT 0,
        \\  PRIMARY KEY(session_id, seq)
        \\);
        \\CREATE INDEX idx_memory_session ON memory_entries(session_id, tombstone);
        \\
        \\CREATE TABLE memory_tags(
        \\  session_id TEXT NOT NULL,
        \\  tag        TEXT NOT NULL,
        \\  UNIQUE(session_id, tag)
        \\);
        ,
    },
    .{
        .name = "0003_instances",
        .sql =
        \\CREATE TABLE instances(
        \\  id                   TEXT    PRIMARY KEY,
        \\  kind                 TEXT    NOT NULL,
        \\  name                 TEXT    NOT NULL DEFAULT '',
        \\  agent_id             TEXT    NOT NULL DEFAULT '',
        \\  session_id           TEXT    NOT NULL DEFAULT '',
        \\  heartbeat_interval_ms INTEGER NOT NULL DEFAULT 0,
        \\  connected_at_ns      BIGINT  NOT NULL,
        \\  last_heartbeat_at_ns BIGINT  NOT NULL,
        \\  evicted_at_ns        BIGINT  NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX idx_instances_kind ON instances(kind);
        \\CREATE INDEX idx_instances_live ON instances(evicted_at_ns) WHERE evicted_at_ns = 0;
        ,
    },
};

pub fn run(db: *sqlite.Db) !void {
    db.lock();
    defer db.unlock();

    const current_version = try db.userVersion();
    var applied: usize = 0;
    var i: usize = @intCast(current_version);
    while (i < all_migrations.len) : (i += 1) {
        const m = all_migrations[i];
        try db.exec("BEGIN IMMEDIATE;");
        db.exec(m.sql) catch |e| {
            db.exec("ROLLBACK;") catch {};
            log.err("migration {s} failed: {s}", .{ m.name, @errorName(e) });
            return e;
        };
        try db.setUserVersion(@intCast(i + 1));
        try db.exec("COMMIT;");
        applied += 1;
        log.info("applied migration {s}", .{m.name});
    }
    if (applied > 0) {
        log.info("schema is at version {d} ({d} migrations applied)", .{
            all_migrations.len,
            applied,
        });
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "migrations: fresh in-memory db lands at the latest version" {
    var db = try sqlite.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();

    try run(&db);
    try testing.expectEqual(@as(i64, all_migrations.len), try db.userVersion());

    // Tables we expect to exist.
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;");
    defer stmt.deinit();

    var tables = std.ArrayList([]u8).empty;
    defer {
        for (tables.items) |t| testing.allocator.free(t);
        tables.deinit(testing.allocator);
    }
    while (try stmt.step()) {
        const t = stmt.columnText(0);
        try tables.append(testing.allocator, try testing.allocator.dupe(u8, t));
    }

    var saw_sessions = false;
    var saw_turns = false;
    var saw_memory = false;
    var saw_instances = false;
    for (tables.items) |t| {
        if (std.mem.eql(u8, t, "sessions")) saw_sessions = true;
        if (std.mem.eql(u8, t, "turns")) saw_turns = true;
        if (std.mem.eql(u8, t, "memory_entries")) saw_memory = true;
        if (std.mem.eql(u8, t, "instances")) saw_instances = true;
    }
    try testing.expect(saw_sessions);
    try testing.expect(saw_turns);
    try testing.expect(saw_memory);
    try testing.expect(saw_instances);
}

test "migrations: re-running on an already-migrated db is a no-op" {
    var db = try sqlite.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();

    try run(&db);
    const after_first = try db.userVersion();
    try run(&db);
    try testing.expectEqual(after_first, try db.userVersion());
}
