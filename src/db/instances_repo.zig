//! Persisted instance registry — CRUD over the `instances` table.
//!
//! Records survive daemon restarts so a TUI that re-attaches with a
//! known id can be reconciled. Eviction is soft: a stale record gets
//! `evicted_at_ns` stamped (non-zero) by the sweeper rather than
//! deleted, so a slow heartbeat that arrives during the eviction
//! window can still find its row and revive it.
//!
//! No clock lives here — the registry layer above injects timestamps.
//! That keeps the repo deterministic under test and lets the
//! sweeper batch its eviction sweep against a single `now`.

const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const Kind = enum {
    tui,
    web,
    cli,
    other,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .tui => "tui",
            .web => "web",
            .cli => "cli",
            .other => "other",
        };
    }

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "tui")) return .tui;
        if (std.mem.eql(u8, s, "web")) return .web;
        if (std.mem.eql(u8, s, "cli")) return .cli;
        if (std.mem.eql(u8, s, "other")) return .other;
        return null;
    }
};

pub const Record = struct {
    id: []const u8,
    kind: Kind,
    name: []const u8 = "",
    agent_id: []const u8 = "",
    session_id: []const u8 = "",
    heartbeat_interval_ms: u32 = 0,
    connected_at_ns: i128,
    last_heartbeat_at_ns: i128,
    evicted_at_ns: i128 = 0,

    pub fn isLive(self: Record) bool {
        return self.evicted_at_ns == 0;
    }
};

/// Borrowed-or-owned record list, returned by `listLive` and
/// friends. Caller deinits to free the per-row allocations.
pub const RecordList = struct {
    allocator: std.mem.Allocator,
    items: []Record,
    /// Owned backing storage for every borrowed string in `items`.
    strings: []u8,

    pub fn deinit(self: *RecordList) void {
        self.allocator.free(self.items);
        self.allocator.free(self.strings);
        self.* = undefined;
    }
};

pub const Repo = struct {
    db: *sqlite.Db,

    pub fn init(db: *sqlite.Db) Repo {
        return .{ .db = db };
    }

    pub fn insert(self: *Repo, rec: Record) !void {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\INSERT INTO instances(
            \\  id, kind, name, agent_id, session_id,
            \\  heartbeat_interval_ms,
            \\  connected_at_ns, last_heartbeat_at_ns, evicted_at_ns
            \\) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
        );
        defer stmt.deinit();

        try stmt.bindText(1, rec.id);
        try stmt.bindText(2, rec.kind.toString());
        try stmt.bindText(3, rec.name);
        try stmt.bindText(4, rec.agent_id);
        try stmt.bindText(5, rec.session_id);
        try stmt.bindInt(6, @intCast(rec.heartbeat_interval_ms));
        try stmt.bindInt(7, @intCast(rec.connected_at_ns));
        try stmt.bindInt(8, @intCast(rec.last_heartbeat_at_ns));
        try stmt.bindInt(9, @intCast(rec.evicted_at_ns));
        _ = try stmt.step();
    }

    /// Stamp the token hash for an existing instance. Called once at
    /// registration time, after `insert`, with the Blake3 hash of the
    /// freshly-generated bearer token. Returns false if the id is
    /// unknown (caller treats as a registration failure).
    pub fn setTokenHash(self: *Repo, id: []const u8, token_hash: []const u8) !bool {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\UPDATE instances SET token_hash = ? WHERE id = ?;
        );
        defer stmt.deinit();
        try stmt.bindText(1, token_hash);
        try stmt.bindText(2, id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    /// Look up the stored token hash for `id`. Returns null when
    /// there is no row, an empty slice when the row exists but has
    /// no token (pre-auth registration), or the 64-char hex digest.
    /// The returned slice is duped onto `allocator`; caller frees.
    pub fn tokenHashFor(
        self: *Repo,
        allocator: std.mem.Allocator,
        id: []const u8,
    ) !?[]u8 {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\SELECT token_hash FROM instances WHERE id = ?;
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);
        if (!try stmt.step()) return null;
        return try allocator.dupe(u8, stmt.columnText(0));
    }

    /// Bump the heartbeat timestamp. Returns `false` when the id is
    /// unknown (caller treats that as 404 — TUI re-registers).
    pub fn heartbeat(self: *Repo, id: []const u8, now_ns: i128) !bool {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\UPDATE instances SET last_heartbeat_at_ns = ?, evicted_at_ns = 0
            \\WHERE id = ?;
        );
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(now_ns));
        try stmt.bindText(2, id);
        _ = try stmt.step();

        return self.db.changes() > 0;
    }

    /// Mark the record evicted (soft). Idempotent.
    pub fn evict(self: *Repo, id: []const u8, now_ns: i128) !void {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\UPDATE instances SET evicted_at_ns = ?
            \\WHERE id = ? AND evicted_at_ns = 0;
        );
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(now_ns));
        try stmt.bindText(2, id);
        _ = try stmt.step();
    }

    /// Hard delete. Used by the sweeper after grace expiry, and by
    /// callers that want a record fully gone (testing tear-down).
    pub fn delete(self: *Repo, id: []const u8) !void {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare("DELETE FROM instances WHERE id = ?;");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        _ = try stmt.step();
    }

    pub fn exists(self: *Repo, id: []const u8) !bool {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare("SELECT 1 FROM instances WHERE id = ?;");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        return try stmt.step();
    }

    pub fn get(self: *Repo, allocator: std.mem.Allocator, id: []const u8) !?Record {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\SELECT id, kind, name, agent_id, session_id,
            \\       heartbeat_interval_ms,
            \\       connected_at_ns, last_heartbeat_at_ns, evicted_at_ns
            \\FROM instances WHERE id = ?;
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);
        if (!try stmt.step()) return null;
        return try rowToRecord(allocator, &stmt);
    }

    pub fn listLive(self: *Repo, allocator: std.mem.Allocator) !RecordList {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\SELECT id, kind, name, agent_id, session_id,
            \\       heartbeat_interval_ms,
            \\       connected_at_ns, last_heartbeat_at_ns, evicted_at_ns
            \\FROM instances WHERE evicted_at_ns = 0
            \\ORDER BY connected_at_ns ASC;
        );
        defer stmt.deinit();
        return try collect(allocator, &stmt);
    }

    /// Find live records whose `last_heartbeat_at_ns + grace < now_ns`
    /// AND whose heartbeat_interval_ms != 0 (heartbeat=0 means the
    /// caller opted out of expiry; only an explicit DELETE evicts
    /// those).
    pub fn findExpired(
        self: *Repo,
        allocator: std.mem.Allocator,
        now_ns: i128,
        grace_ns: i128,
    ) !RecordList {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\SELECT id, kind, name, agent_id, session_id,
            \\       heartbeat_interval_ms,
            \\       connected_at_ns, last_heartbeat_at_ns, evicted_at_ns
            \\FROM instances
            \\WHERE evicted_at_ns = 0
            \\  AND heartbeat_interval_ms > 0
            \\  AND last_heartbeat_at_ns + ? < ?;
        );
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(grace_ns));
        try stmt.bindInt(2, @intCast(now_ns));
        return try collect(allocator, &stmt);
    }

    /// On daemon startup, wipe stale records left from the previous
    /// process. Anything not heartbeat=0 with a heartbeat older than
    /// `now_ns - grace_ns` is presumed dead. Heartbeat=0 records
    /// (declared "I'll DELETE on exit") are kept; the operator can
    /// purge them with `--reset-instances`.
    pub fn reconcileOnStartup(
        self: *Repo,
        now_ns: i128,
        grace_ns: i128,
    ) !void {
        self.db.lock();
        defer self.db.unlock();

        var stmt = try self.db.prepare(
            \\UPDATE instances SET evicted_at_ns = ?
            \\WHERE evicted_at_ns = 0
            \\  AND heartbeat_interval_ms > 0
            \\  AND last_heartbeat_at_ns + ? < ?;
        );
        defer stmt.deinit();
        try stmt.bindInt(1, @intCast(now_ns));
        try stmt.bindInt(2, @intCast(grace_ns));
        try stmt.bindInt(3, @intCast(now_ns));
        _ = try stmt.step();
    }
};

/// Two-pass collection: gather (offset, length) tuples for every
/// string column in the first pass, then resolve to slices into the
/// owned backing buffer at the end. This keeps the row records
/// pointing at stable addresses regardless of how `ArrayList`'s
/// `toOwnedSlice` is implemented.
fn collect(allocator: std.mem.Allocator, stmt: *sqlite.Stmt) !RecordList {
    const Range = struct { off: usize, len: usize };
    const Pending = struct {
        id: Range,
        kind: Kind,
        name: Range,
        agent_id: Range,
        session_id: Range,
        heartbeat_interval_ms: u32,
        connected_at_ns: i128,
        last_heartbeat_at_ns: i128,
        evicted_at_ns: i128,
    };

    var pending = std.ArrayList(Pending).empty;
    errdefer pending.deinit(allocator);

    var strings = std.ArrayList(u8).empty;
    errdefer strings.deinit(allocator);

    while (try stmt.step()) {
        const id_text = stmt.columnText(0);
        const id_off = strings.items.len;
        try strings.appendSlice(allocator, id_text);

        const kind_text = stmt.columnText(1);
        // `kind_text` is read inline and stored as the enum, no need
        // to keep the bytes around.

        const name_text = stmt.columnText(2);
        const name_off = strings.items.len;
        try strings.appendSlice(allocator, name_text);

        const agent_text = stmt.columnText(3);
        const agent_off = strings.items.len;
        try strings.appendSlice(allocator, agent_text);

        const sess_text = stmt.columnText(4);
        const sess_off = strings.items.len;
        try strings.appendSlice(allocator, sess_text);

        try pending.append(allocator, .{
            .id = .{ .off = id_off, .len = id_text.len },
            .kind = Kind.fromString(kind_text) orelse .other,
            .name = .{ .off = name_off, .len = name_text.len },
            .agent_id = .{ .off = agent_off, .len = agent_text.len },
            .session_id = .{ .off = sess_off, .len = sess_text.len },
            .heartbeat_interval_ms = @intCast(stmt.columnInt(5)),
            .connected_at_ns = @intCast(stmt.columnInt(6)),
            .last_heartbeat_at_ns = @intCast(stmt.columnInt(7)),
            .evicted_at_ns = @intCast(stmt.columnInt(8)),
        });
    }

    const owned_strings = try strings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_strings);

    const items = try allocator.alloc(Record, pending.items.len);
    errdefer allocator.free(items);

    for (pending.items, items) |p, *out| {
        out.* = .{
            .id = owned_strings[p.id.off..][0..p.id.len],
            .kind = p.kind,
            .name = owned_strings[p.name.off..][0..p.name.len],
            .agent_id = owned_strings[p.agent_id.off..][0..p.agent_id.len],
            .session_id = owned_strings[p.session_id.off..][0..p.session_id.len],
            .heartbeat_interval_ms = p.heartbeat_interval_ms,
            .connected_at_ns = p.connected_at_ns,
            .last_heartbeat_at_ns = p.last_heartbeat_at_ns,
            .evicted_at_ns = p.evicted_at_ns,
        };
    }
    pending.deinit(allocator);

    return .{
        .allocator = allocator,
        .items = items,
        .strings = owned_strings,
    };
}

fn rowToRecord(allocator: std.mem.Allocator, stmt: *sqlite.Stmt) !Record {
    // Single-row variant: the caller wants an owned record without
    // the bulk machinery of `collect`. Strings get duped onto a
    // small per-record arena that the caller frees by `freeRecord`.
    const id = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(id);
    const kind_str = stmt.columnText(1);
    const name = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(name);
    const agent = try allocator.dupe(u8, stmt.columnText(3));
    errdefer allocator.free(agent);
    const sess = try allocator.dupe(u8, stmt.columnText(4));
    errdefer allocator.free(sess);

    return .{
        .id = id,
        .kind = Kind.fromString(kind_str) orelse .other,
        .name = name,
        .agent_id = agent,
        .session_id = sess,
        .heartbeat_interval_ms = @intCast(stmt.columnInt(5)),
        .connected_at_ns = @intCast(stmt.columnInt(6)),
        .last_heartbeat_at_ns = @intCast(stmt.columnInt(7)),
        .evicted_at_ns = @intCast(stmt.columnInt(8)),
    };
}

pub fn freeRecord(allocator: std.mem.Allocator, rec: Record) void {
    allocator.free(rec.id);
    allocator.free(rec.name);
    allocator.free(rec.agent_id);
    allocator.free(rec.session_id);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const migrations = @import("migrations.zig");

fn freshDb() !sqlite.Db {
    var db = try sqlite.Db.open(testing.allocator, .{ .path = ":memory:" });
    errdefer db.close();
    try migrations.run(&db);
    return db;
}

test "Repo: insert + get + listLive" {
    var db = try freshDb();
    defer db.close();
    var repo = Repo.init(&db);

    try repo.insert(.{
        .id = "tui-aaaaaaaa",
        .kind = .tui,
        .agent_id = "tiger",
        .heartbeat_interval_ms = 0,
        .connected_at_ns = 1000,
        .last_heartbeat_at_ns = 1000,
    });

    const got = (try repo.get(testing.allocator, "tui-aaaaaaaa")).?;
    defer freeRecord(testing.allocator, got);
    try testing.expectEqualStrings("tui-aaaaaaaa", got.id);
    try testing.expectEqual(Kind.tui, got.kind);

    var list = try repo.listLive(testing.allocator);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
}

test "Repo: heartbeat bumps last_heartbeat and revives an evicted record" {
    var db = try freshDb();
    defer db.close();
    var repo = Repo.init(&db);

    try repo.insert(.{
        .id = "tui-bbbbbbbb",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });

    try repo.evict("tui-bbbbbbbb", 5000);
    {
        const r = (try repo.get(testing.allocator, "tui-bbbbbbbb")).?;
        defer freeRecord(testing.allocator, r);
        try testing.expect(!r.isLive());
    }

    try testing.expect(try repo.heartbeat("tui-bbbbbbbb", 6000));
    {
        const r = (try repo.get(testing.allocator, "tui-bbbbbbbb")).?;
        defer freeRecord(testing.allocator, r);
        try testing.expect(r.isLive());
        try testing.expectEqual(@as(i128, 6000), r.last_heartbeat_at_ns);
    }
}

test "Repo: heartbeat on unknown id reports false" {
    var db = try freshDb();
    defer db.close();
    var repo = Repo.init(&db);
    try testing.expect(!(try repo.heartbeat("ghost", 0)));
}

test "Repo: findExpired skips heartbeat=0 records" {
    var db = try freshDb();
    defer db.close();
    var repo = Repo.init(&db);

    try repo.insert(.{
        .id = "tui-forever",
        .kind = .tui,
        .heartbeat_interval_ms = 0, // never expires
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });
    try repo.insert(.{
        .id = "tui-expiring",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });

    var list = try repo.findExpired(testing.allocator, 10_000, 5_000);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("tui-expiring", list.items[0].id);
}

test "Repo: reconcileOnStartup soft-evicts stale heartbeat>0 records" {
    var db = try freshDb();
    defer db.close();
    var repo = Repo.init(&db);

    try repo.insert(.{
        .id = "stale",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });
    try repo.insert(.{
        .id = "fresh",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 9_000,
    });

    try repo.reconcileOnStartup(10_000, 5_000);

    var list = try repo.listLive(testing.allocator);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("fresh", list.items[0].id);
}
