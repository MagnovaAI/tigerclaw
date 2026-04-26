//! Built-in memory provider.
//!
//! Wraps a `SessionStore` (the searchable index of every turn) plus
//! a per-agent `MEMORY.md` file (an append-only, human-readable
//! summary surface). The store answers `prefetch` queries; the file
//! contributes to `systemPromptBlock`. Every turn's user/assistant
//! pair lands in both: the store gets two `Entry` records, the file
//! gets a single dated paragraph.
//!
//! Layout under `state_dir`:
//!   memory/<agent>/MEMORY.md                  current, soft-capped
//!   memory/<agent>/MEMORY.md.<unix-ns>        prior rotations
//!
//! Rotation: when an append would push the file past
//! `rotation_threshold_bytes` (default 1 MiB), the current file is
//! renamed to `MEMORY.md.<now_ns>` and a fresh empty file takes its
//! place before the new line is written. Old rotations are not read
//! by `prefetch` — the searchable index is the SessionStore. The
//! file is the curated summary; rotations preserve history without
//! bloating future reads.

const std = @import("std");
const provider_mod = @import("provider.zig");
const spec = @import("memory_spec");
const clock_mod = @import("clock");

const Io = std.Io;
const MemoryError = provider_mod.MemoryError;

/// Default soft cap: 1 MiB. Append-once-past, then rotate.
pub const default_rotation_threshold_bytes: u64 = 1 * 1024 * 1024;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Root state directory. The provider creates
    /// `memory/<agent>/` lazily on first write.
    state_dir: Io.Dir,
    /// Stable agent name. URL-safe; no `/`. Used as the per-agent
    /// directory name and as the SessionStore session id when
    /// the runner has not yet bound a session.
    agent_name: []const u8,
    /// Optional. When null, builtin operates with a no-op store —
    /// useful for tests that exercise just the MEMORY.md path.
    store: ?spec.SessionStore = null,
    /// Soft cap for MEMORY.md.
    rotation_threshold_bytes: u64 = default_rotation_threshold_bytes,
    /// Wall clock used to stamp turn entries and rotation suffixes.
    /// Tests pass `ManualClock`; production passes `SystemClock`.
    clock: clock_mod.Clock,
};

/// On-disk paths under `state_dir`.
const memory_root = "memory";
const current_file = "MEMORY.md";

pub const Builtin = struct {
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    agent_name: []const u8,
    store: ?spec.SessionStore,
    rotation_threshold_bytes: u64,
    clock: clock_mod.Clock,

    /// `agent_dir` is opened lazily on first write so init is free
    /// of filesystem side effects. Subsequent writes reuse the
    /// handle until shutdown.
    agent_dir: ?Io.Dir = null,

    /// Cached system-prompt block. Built once on demand from the
    /// current `MEMORY.md`. Invalidated by syncTurn (which appends).
    /// Owned by `allocator`; freed on shutdown and on rebuild.
    cached_block: ?[]u8 = null,

    /// Last prefetch result text. Owned by `allocator`. The vtable
    /// contract says prefetch's slice is valid until the next call
    /// on the same provider; this slot holds that backing buffer.
    last_prefetch: ?[]u8 = null,

    pub fn init(opts: Options) Builtin {
        return .{
            .allocator = opts.allocator,
            .io = opts.io,
            .state_dir = opts.state_dir,
            .agent_name = opts.agent_name,
            .store = opts.store,
            .rotation_threshold_bytes = opts.rotation_threshold_bytes,
            .clock = opts.clock,
        };
    }

    pub fn provider(self: *Builtin) provider_mod.Provider {
        return .{
            .ptr = self,
            .vtable = &vt,
            .kind = .builtin,
            .name = "builtin",
        };
    }

    // --- vtable shims ------------------------------------------------------

    const vt: provider_mod.VTable = .{
        .initialize = initializeFn,
        .system_prompt_block = systemPromptBlockFn,
        .prefetch = prefetchFn,
        .sync_turn = syncTurnFn,
        .shutdown = shutdownFn,
    };

    fn initializeFn(p: *anyopaque) MemoryError!void {
        const self: *Builtin = @ptrCast(@alignCast(p));
        return self.initialize();
    }

    fn systemPromptBlockFn(p: *anyopaque) MemoryError![]const u8 {
        const self: *Builtin = @ptrCast(@alignCast(p));
        return self.systemPromptBlock();
    }

    fn prefetchFn(p: *anyopaque, query: []const u8) MemoryError!provider_mod.Prefetch {
        const self: *Builtin = @ptrCast(@alignCast(p));
        return self.prefetch(query);
    }

    fn syncTurnFn(p: *anyopaque, pair: provider_mod.TurnPair) MemoryError!void {
        const self: *Builtin = @ptrCast(@alignCast(p));
        return self.syncTurn(pair);
    }

    fn shutdownFn(p: *anyopaque) void {
        const self: *Builtin = @ptrCast(@alignCast(p));
        self.shutdown();
    }

    // --- impl --------------------------------------------------------------

    pub fn initialize(self: *Builtin) MemoryError!void {
        // Create memory/<agent>/ on demand. createDirPath is
        // idempotent so this is safe across restarts.
        var path_buf: [256]u8 = undefined;
        const sub = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ memory_root, self.agent_name }) catch
            return MemoryError.BackendFailure;
        self.state_dir.createDirPath(self.io, sub) catch return MemoryError.BackendFailure;
        const dir = self.state_dir.openDir(self.io, sub, .{}) catch return MemoryError.BackendFailure;
        self.agent_dir = dir;
    }

    pub fn shutdown(self: *Builtin) void {
        if (self.cached_block) |b| {
            self.allocator.free(b);
            self.cached_block = null;
        }
        if (self.last_prefetch) |b| {
            self.allocator.free(b);
            self.last_prefetch = null;
        }
        if (self.agent_dir) |*d| {
            d.close(self.io);
            self.agent_dir = null;
        }
    }

    /// Read the current MEMORY.md and return it as the system-prompt
    /// block. Empty file → empty block. The slice is owned by the
    /// builtin and valid until the next syncTurn.
    pub fn systemPromptBlock(self: *Builtin) MemoryError![]const u8 {
        if (self.cached_block) |b| return b;

        const dir = self.agent_dir orelse return "";
        const file = dir.openFile(self.io, current_file, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => {
                const empty = self.allocator.alloc(u8, 0) catch return MemoryError.OutOfMemory;
                self.cached_block = empty;
                return empty;
            },
            else => return MemoryError.BackendFailure,
        };
        defer file.close(self.io);

        const len = file.length(self.io) catch return MemoryError.BackendFailure;
        if (len == 0) {
            const empty = self.allocator.alloc(u8, 0) catch return MemoryError.OutOfMemory;
            self.cached_block = empty;
            return empty;
        }

        const buf = self.allocator.alloc(u8, len) catch return MemoryError.OutOfMemory;
        errdefer self.allocator.free(buf);

        var read_buf: [1024]u8 = undefined;
        var r = file.reader(self.io, &read_buf);
        r.interface.readSliceAll(buf) catch return MemoryError.BackendFailure;

        self.cached_block = buf;
        return buf;
    }

    /// `prefetch` queries the SessionStore (when present) and
    /// returns the matching entries concatenated. With no store the
    /// result is empty — the runner sees that as "no context" and
    /// skips injection.
    pub fn prefetch(self: *Builtin, query: []const u8) MemoryError!provider_mod.Prefetch {
        if (query.len == 0) return MemoryError.InvalidQuery;

        // Free the previous backing buffer; vtable contract says it
        // is only valid until the next call.
        if (self.last_prefetch) |b| {
            self.allocator.free(b);
            self.last_prefetch = null;
        }

        const store = self.store orelse return .{ .text = "" };

        var entries: [16]spec.Entry = undefined;
        const got = store.search(self.agent_name, .{ .text = query, .limit = entries.len }, &entries) catch
            return MemoryError.BackendFailure;
        if (got == 0) return .{ .text = "" };

        // Concatenate `kind: body\n` for each match into one buffer.
        var total: usize = 0;
        for (entries[0..got]) |e| total += e.body.len + 16;

        const out = self.allocator.alloc(u8, total) catch return MemoryError.OutOfMemory;
        errdefer self.allocator.free(out);

        var written: usize = 0;
        for (entries[0..got]) |e| {
            const tag = @tagName(e.kind);
            const line = std.fmt.bufPrint(out[written..], "{s}: {s}\n", .{ tag, e.body }) catch
                return MemoryError.BackendFailure;
            written += line.len;
        }

        // Shrink to actual written length.
        const shrunk = self.allocator.realloc(out, written) catch out[0..written];
        self.last_prefetch = shrunk;
        return .{ .text = shrunk };
    }

    /// Append the user/assistant pair to both the store and the
    /// MEMORY.md file. Rotation runs before the file write when the
    /// existing file would push past the threshold.
    pub fn syncTurn(self: *Builtin, pair: provider_mod.TurnPair) MemoryError!void {
        if (self.store) |store| {
            _ = store.append(self.agent_name, .{ .kind = .user, .body = pair.user }) catch
                return MemoryError.BackendFailure;
            _ = store.append(self.agent_name, .{ .kind = .assistant, .body = pair.assistant }) catch
                return MemoryError.BackendFailure;
        }

        try self.appendToMemoryFile(pair);

        // Cached block is now stale.
        if (self.cached_block) |b| {
            self.allocator.free(b);
            self.cached_block = null;
        }
    }

    fn appendToMemoryFile(self: *Builtin, pair: provider_mod.TurnPair) MemoryError!void {
        const dir = self.agent_dir orelse return MemoryError.BackendFailure;

        // Compose the line up front so we can size the rotation
        // decision on actual bytes-to-write, not an estimate.
        const ts = self.clock.nowNs();
        const line = std.fmt.allocPrint(
            self.allocator,
            "## turn @ {d}\n- user: {s}\n- assistant: {s}\n\n",
            .{ ts, pair.user, pair.assistant },
        ) catch return MemoryError.OutOfMemory;
        defer self.allocator.free(line);

        const existing_len: u64 = blk: {
            const stat = dir.statFile(self.io, current_file, .{}) catch |e| switch (e) {
                error.FileNotFound => break :blk 0,
                else => return MemoryError.BackendFailure,
            };
            break :blk stat.size;
        };

        if (existing_len > 0 and existing_len + line.len > self.rotation_threshold_bytes) {
            try self.rotate(ts);
        }

        // Open with truncate=false so we append; positional write at
        // current length matches the LogSink pattern in the daemon.
        const file = dir.createFile(self.io, current_file, .{
            .truncate = false,
            .read = false,
        }) catch return MemoryError.BackendFailure;
        defer file.close(self.io);

        const offset = file.length(self.io) catch return MemoryError.BackendFailure;
        file.writePositionalAll(self.io, line, offset) catch
            return MemoryError.BackendFailure;
    }

    fn rotate(self: *Builtin, ts: i128) MemoryError!void {
        const dir = self.agent_dir orelse return MemoryError.BackendFailure;
        var name_buf: [64]u8 = undefined;
        const new_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ current_file, ts }) catch
            return MemoryError.BackendFailure;
        dir.rename(current_file, dir, new_name, self.io) catch return MemoryError.BackendFailure;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Builtin: initialize creates per-agent dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "concierge",
        .clock = mc.clock(),
    });
    defer b.shutdown();

    try b.initialize();

    var sub = try tmp.dir.openDir(testing.io, "memory/concierge", .{});
    sub.close(testing.io);
}

test "Builtin: systemPromptBlock returns empty when MEMORY.md missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    const block = try b.systemPromptBlock();
    try testing.expectEqual(@as(usize, 0), block.len);
}

test "Builtin: syncTurn appends to MEMORY.md and updates the cached block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 42 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    try b.syncTurn(.{ .user = "hi", .assistant = "hello" });

    const block = try b.systemPromptBlock();
    try testing.expect(std.mem.indexOf(u8, block, "user: hi") != null);
    try testing.expect(std.mem.indexOf(u8, block, "assistant: hello") != null);
    try testing.expect(std.mem.indexOf(u8, block, "turn @ 42") != null);
}

test "Builtin: syncTurn invalidates the cached block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    try b.syncTurn(.{ .user = "first", .assistant = "one" });
    const first = try b.systemPromptBlock();
    const first_copy = try testing.allocator.dupe(u8, first);
    defer testing.allocator.free(first_copy);

    mc.advance(1);
    try b.syncTurn(.{ .user = "second", .assistant = "two" });
    const second = try b.systemPromptBlock();

    try testing.expect(second.len > first_copy.len);
    try testing.expect(std.mem.indexOf(u8, second, "second") != null);
}

test "Builtin: rotation triggers when next write crosses the threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1000 };

    // Tiny threshold so any line crosses it.
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .rotation_threshold_bytes = 32,
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    try b.syncTurn(.{ .user = "u1", .assistant = "a1" });
    mc.value_ns = 2000;
    try b.syncTurn(.{ .user = "u2", .assistant = "a2" }); // should rotate

    var dir = try tmp.dir.openDir(testing.io, "memory/a1", .{ .iterate = true });
    defer dir.close(testing.io);
    var iter = dir.iterate();

    var saw_current = false;
    var saw_rotation = false;
    while (try iter.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "MEMORY.md")) saw_current = true;
        if (std.mem.startsWith(u8, entry.name, "MEMORY.md.")) saw_rotation = true;
    }
    try testing.expect(saw_current);
    try testing.expect(saw_rotation);
}

test "Builtin: prefetch on empty store returns empty text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    const got = try b.prefetch("anything");
    try testing.expectEqual(@as(usize, 0), got.text.len);
}

test "Builtin: prefetch with empty query is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 0 };
    var b = Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a1",
        .clock = mc.clock(),
    });
    defer b.shutdown();
    try b.initialize();

    try testing.expectError(MemoryError.InvalidQuery, b.prefetch(""));
}
