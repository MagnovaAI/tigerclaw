//! Background sweeper for the instance registry.
//!
//! Two passes per tick, each its own SQL UPDATE/DELETE:
//!   1. Soft-evict any live row whose heartbeat is older than its
//!      configured grace window. The row stays in the table so a
//!      slow heartbeat that arrives during the eviction window can
//!      revive it (`Repo.heartbeat` clears `evicted_at_ns`).
//!   2. Hard-delete any soft-evicted row that has been evicted for
//!      more than `purge_after_ns`. This bounds the table under
//!      churn without operator intervention.
//!
//! The sweeper is its own thread because the alternative — sweeping
//! inline on each heartbeat — couples the eviction policy to TUI
//! traffic patterns. A long quiet period would skip eviction; a
//! sudden burst would do too much work on the request hot path.
//! Polling is fine here: instance churn is on the order of
//! seconds-to-minutes, not milliseconds.
//!
//! Lifecycle: `start` spawns the loop; `stop` flips the cancel flag
//! and joins. The Boot layer calls `stop` before closing the DB so
//! the loop never touches a destroyed handle.

const std = @import("std");
const db_mod = @import("../db/root.zig");
const clock_mod = @import("clock");

pub const Options = struct {
    /// How often to wake and check for expired rows. Tests inject a
    /// 1ms tick; production wires something on the order of seconds.
    tick_interval_ns: u64 = 5 * std.time.ns_per_s,
    /// Soft-evict a row whose last heartbeat is older than
    /// `last_heartbeat_at_ns + grace_ns < now_ns`. Default = 30s,
    /// roughly 3× the typical TUI heartbeat cadence.
    grace_ns: i128 = 30 * std.time.ns_per_s,
    /// Hard-delete a soft-evicted row this long after eviction.
    /// Default = 5 minutes, plenty of time for a flaky client to
    /// reconnect and revive itself before the slot is reclaimed.
    purge_after_ns: i128 = 5 * std.time.ns_per_min,
};

pub const Sweeper = struct {
    db: *db_mod.Db,
    clock: clock_mod.Clock,
    io: std.Io,
    opts: Options,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(db: *db_mod.Db, clock: clock_mod.Clock, io: std.Io, opts: Options) Sweeper {
        return .{ .db = db, .clock = clock, .io = io, .opts = opts };
    }

    pub fn start(self: *Sweeper) std.Thread.SpawnError!void {
        if (self.thread != null) return;
        self.cancel.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Flip cancel and join. Safe if `start` was never called. The
    /// loop checks the cancel flag every `tick_interval_ns`, so the
    /// drain may pause up to that long waiting for the join — pick
    /// a small enough tick that this is not a problem in practice.
    pub fn stop(self: *Sweeper) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Run one sweep pass synchronously. Exposed for tests and for
    /// the boot-time reconcile path; the loop calls this from its
    /// thread on each tick.
    pub fn sweepOnce(self: *Sweeper) !struct { evicted: i64, purged: i64 } {
        var repo = db_mod.InstanceRepo.init(self.db);
        const now_ns = self.clock.nowNs();
        const evicted = try repo.evictExpired(now_ns, self.opts.grace_ns);
        const purged = try repo.purgeEvicted(now_ns, self.opts.purge_after_ns);
        return .{ .evicted = evicted, .purged = purged };
    }
};

fn loop(self: *Sweeper) void {
    const log = std.log.scoped(.instance_sweeper);
    while (!self.cancel.load(.acquire)) {
        _ = self.sweepOnce() catch |err| {
            // SQLite errors here are surprising but not fatal — log
            // and try again next tick rather than killing the thread,
            // which would leave the registry growing without bound.
            log.warn("sweep failed: {s}", .{@errorName(err)});
        };

        // Sleep one tick. `Io.sleep` returns Cancelable — when the
        // gateway is shutting down it surfaces as an error and we
        // exit the loop next iteration via the cancel-flag check.
        std.Io.sleep(
            self.io,
            std.Io.Duration.fromNanoseconds(@intCast(self.opts.tick_interval_ns)),
            .awake,
        ) catch return;
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "sweepOnce: soft-evicts a row whose heartbeat aged past grace" {
    var db = try db_mod.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();
    try db_mod.migrations.run(&db);

    var repo = db_mod.InstanceRepo.init(&db);
    try repo.insert(.{
        .id = "tui-aged",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });

    var clock_state: clock_mod.FixedClock = .{ .value_ns = 10 * std.time.ns_per_s };
    var sweeper = Sweeper.init(&db, clock_state.clock(), testing.io, .{
        .grace_ns = 5 * std.time.ns_per_s,
        .purge_after_ns = std.math.maxInt(i64),
    });
    const result = try sweeper.sweepOnce();
    try testing.expectEqual(@as(i64, 1), result.evicted);
    try testing.expectEqual(@as(i64, 0), result.purged);

    const rec = (try repo.get(testing.allocator, "tui-aged")) orelse return error.TestUnexpectedNull;
    defer {
        testing.allocator.free(rec.id);
        testing.allocator.free(rec.name);
        testing.allocator.free(rec.agent_id);
        testing.allocator.free(rec.session_id);
    }
    try testing.expect(rec.evicted_at_ns > 0);
}

test "sweepOnce: hard-deletes a row evicted past purge_after" {
    var db = try db_mod.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();
    try db_mod.migrations.run(&db);

    var repo = db_mod.InstanceRepo.init(&db);
    try repo.insert(.{
        .id = "tui-old-evict",
        .kind = .tui,
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
        .evicted_at_ns = 1000,
    });

    var clock_state: clock_mod.FixedClock = .{ .value_ns = 1_000_000_000 };
    var sweeper = Sweeper.init(&db, clock_state.clock(), testing.io, .{
        .grace_ns = std.math.maxInt(i64),
        .purge_after_ns = 1, // anything older than 1ns is purgeable
    });
    const result = try sweeper.sweepOnce();
    try testing.expectEqual(@as(i64, 1), result.purged);
    try testing.expect(!(try repo.exists("tui-old-evict")));
}

test "sweepOnce: leaves heartbeat=0 rows alone" {
    var db = try db_mod.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();
    try db_mod.migrations.run(&db);

    var repo = db_mod.InstanceRepo.init(&db);
    try repo.insert(.{
        .id = "cli-eternal",
        .kind = .cli,
        .heartbeat_interval_ms = 0, // opted out of expiry
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });

    var clock_state: clock_mod.FixedClock = .{ .value_ns = std.math.maxInt(i64) };
    var sweeper = Sweeper.init(&db, clock_state.clock(), testing.io, .{
        .grace_ns = 1,
        .purge_after_ns = 1,
    });
    const result = try sweeper.sweepOnce();
    try testing.expectEqual(@as(i64, 0), result.evicted);
    try testing.expectEqual(@as(i64, 0), result.purged);
    try testing.expect(try repo.exists("cli-eternal"));
}

test "start/stop: thread joins cleanly" {
    var db = try db_mod.Db.open(testing.allocator, .{ .path = ":memory:" });
    defer db.close();
    try db_mod.migrations.run(&db);

    var clock_state: clock_mod.FixedClock = .{ .value_ns = 0 };
    var sweeper = Sweeper.init(&db, clock_state.clock(), testing.io, .{
        .tick_interval_ns = 1 * std.time.ns_per_s, // long, the test relies on `stop` waking it early
    });
    try sweeper.start();
    sweeper.stop();
}
