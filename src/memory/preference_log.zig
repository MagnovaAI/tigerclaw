//! Preference log — JSONL turn-end records for the audit substrate.
//!
//! Why this and not RLHF: tigerclaw is inference, not training.
//! What people actually mean by "RLHF in an agent" is *preference
//! data collection*. That is this module. A future +1/-1 signal
//! from a TUI thumbs-up or a Discord reaction joins the same JSONL
//! with a `signal` field — no schema change, same audit table.
//! Bandit routing and critic-in-the-loop want this exact data as
//! their input; landing the substrate now lets those land later
//! without a new persistence story.
//!
//! Layout under `state_dir`:
//!   audit/preferences.jsonl                   current, rotated at N MiB
//!   audit/preferences.jsonl.<unix-ns>         rotations
//!
//! Hashes: blake3 truncated to 16 bytes (32 hex chars). Truncated
//! blake3 collides at ~2^64 inputs, which is generous for any
//! realistic preference table. SHA-256 truncated would also work;
//! blake3 is faster and the hex field is shorter at this width.
//! Hashes (not raw text) so the audit trail isn't a transcript
//! dump — the user's words land in the SessionStore already.

const std = @import("std");

const Io = std.Io;
const clock_mod = @import("clock");

/// Soft cap before rotation. JSONL is line-per-turn so a 16 MiB
/// file holds tens of millions of turns; the cap exists so a single
/// long-lived process doesn't grow an unbounded blob.
pub const default_rotation_threshold_bytes: u64 = 16 * 1024 * 1024;

const audit_dir = "audit";
const current_file = "preferences.jsonl";

/// Hex-encoded 16-byte digest. 32 ASCII chars + null sentinel for
/// printf safety; only the first 32 bytes are meaningful.
pub const HashHex = [32]u8;

pub fn hashBlake3Truncated(input: []const u8) HashHex {
    var raw: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(input, &raw, .{});
    var hex: HashHex = undefined;
    const charset = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        hex[i * 2 + 0] = charset[(b >> 4) & 0xF];
        hex[i * 2 + 1] = charset[b & 0xF];
    }
    return hex;
}

/// One turn-end record. Hashes are caller-supplied so callers can
/// feed structured shapes (multi-block messages) through their own
/// canonicalisation before hashing.
pub const TurnEnd = struct {
    turn_id: u64,
    agent_id: []const u8,
    session_id: []const u8,
    user_input_hash: HashHex,
    output_hash: HashHex,
    model: []const u8,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    latency_ms: u64 = 0,
    completed: bool = true,
    ts_ns: i128,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Root state directory. The log creates `audit/` lazily on
    /// first write.
    state_dir: Io.Dir,
    rotation_threshold_bytes: u64 = default_rotation_threshold_bytes,
    clock: clock_mod.Clock,
};

pub const Error = error{
    BackendFailure,
    OutOfMemory,
};

pub const PreferenceLog = struct {
    allocator: std.mem.Allocator,
    io: Io,
    state_dir: Io.Dir,
    rotation_threshold_bytes: u64,
    clock: clock_mod.Clock,

    audit_dir_handle: ?Io.Dir = null,

    pub fn init(opts: Options) Error!PreferenceLog {
        var pl: PreferenceLog = .{
            .allocator = opts.allocator,
            .io = opts.io,
            .state_dir = opts.state_dir,
            .rotation_threshold_bytes = opts.rotation_threshold_bytes,
            .clock = opts.clock,
        };
        pl.state_dir.createDirPath(pl.io, audit_dir) catch return Error.BackendFailure;
        pl.audit_dir_handle = pl.state_dir.openDir(pl.io, audit_dir, .{}) catch
            return Error.BackendFailure;
        return pl;
    }

    pub fn deinit(self: *PreferenceLog) void {
        if (self.audit_dir_handle) |*d| {
            d.close(self.io);
            self.audit_dir_handle = null;
        }
    }

    /// Append one turn-end record. Rotates the current file before
    /// the write when adding this line would push past the soft cap.
    pub fn record(self: *PreferenceLog, entry: TurnEnd) Error!void {
        const dir = self.audit_dir_handle orelse return Error.BackendFailure;

        const line = try renderLine(self.allocator, entry);
        defer self.allocator.free(line);

        const existing_len: u64 = blk: {
            const stat = dir.statFile(self.io, current_file, .{}) catch |e| switch (e) {
                error.FileNotFound => break :blk 0,
                else => return Error.BackendFailure,
            };
            break :blk stat.size;
        };

        if (existing_len > 0 and existing_len + line.len > self.rotation_threshold_bytes) {
            try self.rotate();
        }

        const file = dir.createFile(self.io, current_file, .{
            .truncate = false,
            .read = false,
        }) catch return Error.BackendFailure;
        defer file.close(self.io);

        const offset = file.length(self.io) catch return Error.BackendFailure;
        file.writePositionalAll(self.io, line, offset) catch return Error.BackendFailure;
    }

    fn rotate(self: *PreferenceLog) Error!void {
        const dir = self.audit_dir_handle orelse return Error.BackendFailure;
        const ts = self.clock.nowNs();
        var name_buf: [64]u8 = undefined;
        const new_name = std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ current_file, ts }) catch
            return Error.BackendFailure;
        dir.rename(current_file, dir, new_name, self.io) catch return Error.BackendFailure;
    }
};

/// Render one TurnEnd as a single JSON line ending in '\n'. Caller
/// owns the returned slice.
fn renderLine(allocator: std.mem.Allocator, entry: TurnEnd) Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var w = &aw.writer;

    w.writeAll("{\"turn_id\":") catch return Error.OutOfMemory;
    w.print("{d}", .{entry.turn_id}) catch return Error.OutOfMemory;

    w.writeAll(",\"agent_id\":") catch return Error.OutOfMemory;
    std.json.Stringify.encodeJsonString(entry.agent_id, .{}, w) catch return Error.OutOfMemory;

    w.writeAll(",\"session_id\":") catch return Error.OutOfMemory;
    std.json.Stringify.encodeJsonString(entry.session_id, .{}, w) catch return Error.OutOfMemory;

    w.writeAll(",\"user_input_hash\":\"") catch return Error.OutOfMemory;
    w.writeAll(&entry.user_input_hash) catch return Error.OutOfMemory;
    w.writeAll("\"") catch return Error.OutOfMemory;

    w.writeAll(",\"output_hash\":\"") catch return Error.OutOfMemory;
    w.writeAll(&entry.output_hash) catch return Error.OutOfMemory;
    w.writeAll("\"") catch return Error.OutOfMemory;

    w.writeAll(",\"model\":") catch return Error.OutOfMemory;
    std.json.Stringify.encodeJsonString(entry.model, .{}, w) catch return Error.OutOfMemory;

    w.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"latency_ms\":{d},\"completed\":{any},\"ts_ns\":{d}}}\n",
        .{ entry.input_tokens, entry.output_tokens, entry.latency_ms, entry.completed, entry.ts_ns },
    ) catch return Error.OutOfMemory;

    return aw.toOwnedSlice() catch return Error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "hashBlake3Truncated: stable hex output of length 32" {
    const a = hashBlake3Truncated("hello");
    const b = hashBlake3Truncated("hello");
    try testing.expectEqualSlices(u8, &a, &b);

    const c = hashBlake3Truncated("hello!");
    try testing.expect(!std.mem.eql(u8, &a, &c));

    // All chars must be lower-case hex.
    for (a) |ch| try testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
}

test "PreferenceLog: record appends one JSONL line that parses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 42 };
    var pl = try PreferenceLog.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .clock = mc.clock(),
    });
    defer pl.deinit();

    try pl.record(.{
        .turn_id = 7,
        .agent_id = "tiger",
        .session_id = "sess-1",
        .user_input_hash = hashBlake3Truncated("hi"),
        .output_hash = hashBlake3Truncated("hello"),
        .model = "claude-mock-0",
        .input_tokens = 3,
        .output_tokens = 5,
        .latency_ms = 12,
        .completed = true,
        .ts_ns = 1_700_000_000_000,
    });

    var dir = try tmp.dir.openDir(testing.io, audit_dir, .{});
    defer dir.close(testing.io);

    var buf: [1024]u8 = undefined;
    const bytes = try dir.readFile(testing.io, current_file, &buf);
    try testing.expect(bytes.len > 0);
    try testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);

    // Must be parseable.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        bytes[0 .. bytes.len - 1],
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("turn_id").?.integer);
    try testing.expectEqualStrings("tiger", parsed.value.object.get("agent_id").?.string);
    try testing.expectEqualStrings("claude-mock-0", parsed.value.object.get("model").?.string);
    try testing.expectEqual(true, parsed.value.object.get("completed").?.bool);
}

test "PreferenceLog: rotation triggers when next line crosses the threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1_000 };
    var pl = try PreferenceLog.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .rotation_threshold_bytes = 64, // tiny so any line crosses it
        .clock = mc.clock(),
    });
    defer pl.deinit();

    try pl.record(.{
        .turn_id = 1,
        .agent_id = "a",
        .session_id = "s",
        .user_input_hash = hashBlake3Truncated("u1"),
        .output_hash = hashBlake3Truncated("o1"),
        .model = "m",
        .ts_ns = 1,
    });
    mc.value_ns = 2_000;
    try pl.record(.{
        .turn_id = 2,
        .agent_id = "a",
        .session_id = "s",
        .user_input_hash = hashBlake3Truncated("u2"),
        .output_hash = hashBlake3Truncated("o2"),
        .model = "m",
        .ts_ns = 2,
    });

    var dir = try tmp.dir.openDir(testing.io, audit_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var iter = dir.iterate();

    var saw_current = false;
    var saw_rotation = false;
    while (try iter.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, current_file)) saw_current = true;
        if (std.mem.startsWith(u8, entry.name, current_file ++ ".")) saw_rotation = true;
    }
    try testing.expect(saw_current);
    try testing.expect(saw_rotation);
}

test "PreferenceLog: append-only (re-init reads existing offset)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    {
        var pl = try PreferenceLog.init(.{
            .allocator = testing.allocator,
            .io = testing.io,
            .state_dir = tmp.dir,
            .clock = mc.clock(),
        });
        defer pl.deinit();
        try pl.record(.{
            .turn_id = 1,
            .agent_id = "a",
            .session_id = "s",
            .user_input_hash = hashBlake3Truncated("hi"),
            .output_hash = hashBlake3Truncated("hello"),
            .model = "m",
            .ts_ns = 1,
        });
    }
    {
        var pl = try PreferenceLog.init(.{
            .allocator = testing.allocator,
            .io = testing.io,
            .state_dir = tmp.dir,
            .clock = mc.clock(),
        });
        defer pl.deinit();
        try pl.record(.{
            .turn_id = 2,
            .agent_id = "a",
            .session_id = "s",
            .user_input_hash = hashBlake3Truncated("hi2"),
            .output_hash = hashBlake3Truncated("hello2"),
            .model = "m",
            .ts_ns = 2,
        });
    }

    var dir = try tmp.dir.openDir(testing.io, audit_dir, .{});
    defer dir.close(testing.io);
    var buf: [4096]u8 = undefined;
    const bytes = try dir.readFile(testing.io, current_file, &buf);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |ln| if (ln.len > 0) {
        lines += 1;
    };
    try testing.expectEqual(@as(usize, 2), lines);
}
