//! Loader for the on-disk agents layout at `~/.tigerclaw/agents/`.
//!
//! Produces an `AgentsConfig` value that `channels/startup.zig` walks
//! to open bots + register them on the channel manager. The layout:
//!
//!   ~/.tigerclaw/
//!     config.json                           -- provider API keys
//!     agents/
//!       <name>/
//!         agent.json                        -- provider, model, channels
//!         SOUL.md                           -- optional system prompt
//!
//! # agent.json shape (additive over v0.1.0)
//!
//! {
//!   "name": "tiger",
//!   "provider": "anthropic",
//!   "model": "claude-haiku-4-5-20251001",
//!   "channels": [
//!     {
//!       "kind": "telegram",
//!       "account": "tobi374758_bot",
//!       "token_env": "TIGERCLAW_TG_TOKEN"
//!     }
//!   ]
//! }
//!
//! Missing `channels` → agent has no external surface (a CLI-only
//! agent). Present but with more than one entry violates the v0.1.0
//! "one channel account = one agent" rule and gets rejected.

const std = @import("std");
const agents_cfg = @import("../../settings/agents.zig");

pub const LoadError = error{
    HomeMissing,
    AgentsDirMissing,
    AgentParseFailed,
    UnknownChannelKind,
    OutOfMemory,
} || std.mem.Allocator.Error;

/// Load every agent under `<home>/.tigerclaw/agents/` and return a
/// validated `AgentsConfig`. Caller owns `config.entries` strings via
/// the returned arena — deinit to release.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    config: agents_cfg.AgentsConfig,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

pub fn loadFromHome(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) LoadError!Loaded {
    if (home.len == 0) return error.HomeMissing;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agents_dir_path = std.fmt.bufPrint(&path_buf, "{s}/.tigerclaw/agents", .{home}) catch
        return error.AgentsDirMissing;

    var dir = std.Io.Dir.cwd().openDir(io, agents_dir_path, .{ .iterate = true }) catch
        return error.AgentsDirMissing;
    defer dir.close(io);

    var entries: std.ArrayList(agents_cfg.AgentConfig) = .empty;
    defer entries.deinit(aa);

    var it = dir.iterate(io);
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const loaded = loadOne(aa, io, dir, entry.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue, // skip malformed agent dirs, keep going
        };
        try entries.append(aa, loaded);
    }

    const entries_slice = try entries.toOwnedSlice(aa);
    const default_name = if (entries_slice.len > 0)
        try aa.dupe(u8, entries_slice[0].name)
    else
        "cli";

    return .{
        .arena = arena,
        .config = .{ .default = default_name, .entries = entries_slice },
    };
}

fn loadOne(
    arena_alloc: std.mem.Allocator,
    io: std.Io,
    agents_dir: std.Io.Dir,
    name: []const u8,
) LoadError!agents_cfg.AgentConfig {
    var sub_buf: [128]u8 = undefined;
    const agent_path = std.fmt.bufPrint(&sub_buf, "{s}/agent.json", .{name}) catch
        return error.AgentParseFailed;

    const bytes = agents_dir.readFileAlloc(io, agent_path, arena_alloc, .limited(16 * 1024)) catch
        return error.AgentParseFailed;

    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, bytes, .{}) catch
        return error.AgentParseFailed;

    const root = parsed.value;
    if (root != .object) return error.AgentParseFailed;

    const name_v = root.object.get("name") orelse return error.AgentParseFailed;
    if (name_v != .string) return error.AgentParseFailed;

    const provider_v = root.object.get("provider") orelse return error.AgentParseFailed;
    if (provider_v != .string) return error.AgentParseFailed;

    const model_v = root.object.get("model") orelse return error.AgentParseFailed;
    if (model_v != .string) return error.AgentParseFailed;

    const channels = try parseChannels(arena_alloc, root);

    return .{
        .name = try arena_alloc.dupe(u8, name_v.string),
        .persona = "",
        .provider = try arena_alloc.dupe(u8, provider_v.string),
        .model = try arena_alloc.dupe(u8, model_v.string),
        .monthly_budget_cents = 0,
        .enabled = true,
        .channels = channels,
        .memory = .{},
    };
}

fn parseChannels(
    arena_alloc: std.mem.Allocator,
    root: std.json.Value,
) LoadError![]const agents_cfg.ChannelRef {
    const channels_v = root.object.get("channels") orelse {
        // Agent has no external surface; fabricate a cli channel so
        // the v0.1.0 validator (which requires exactly one) passes.
        const arr = try arena_alloc.alloc(agents_cfg.ChannelRef, 1);
        arr[0] = .{ .kind = .cli, .account = "stdin", .token_env = null };
        return arr;
    };
    if (channels_v != .array) return error.AgentParseFailed;

    const items = channels_v.array.items;
    if (items.len == 0) return error.AgentParseFailed;

    const out = try arena_alloc.alloc(agents_cfg.ChannelRef, items.len);
    for (items, 0..) |raw, i| {
        if (raw != .object) return error.AgentParseFailed;
        const kind_v = raw.object.get("kind") orelse return error.AgentParseFailed;
        if (kind_v != .string) return error.AgentParseFailed;
        const kind = std.meta.stringToEnum(agents_cfg.ChannelKind, kind_v.string) orelse
            return error.UnknownChannelKind;

        const account_v = raw.object.get("account") orelse return error.AgentParseFailed;
        if (account_v != .string) return error.AgentParseFailed;

        const token_env: ?[]const u8 = blk: {
            const t = raw.object.get("token_env") orelse break :blk null;
            if (t != .string) break :blk null;
            break :blk try arena_alloc.dupe(u8, t.string);
        };

        out[i] = .{
            .kind = kind,
            .account = try arena_alloc.dupe(u8, account_v.string),
            .token_env = token_env,
        };
    }
    return out;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "loadFromHome: empty home returns HomeMissing" {
    try testing.expectError(error.HomeMissing, loadFromHome(testing.allocator, testing.io, ""));
}

test "parseChannels: missing key synthesizes a cli channel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{}", .{});
    const channels = try parseChannels(arena.allocator(), parsed.value);
    try testing.expectEqual(@as(usize, 1), channels.len);
    try testing.expectEqual(agents_cfg.ChannelKind.cli, channels[0].kind);
}

test "parseChannels: explicit telegram entry round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bytes =
        \\{"channels":[{"kind":"telegram","account":"tobi374758_bot","token_env":"TIGERCLAW_TG_TOKEN"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), bytes, .{});
    const channels = try parseChannels(arena.allocator(), parsed.value);
    try testing.expectEqual(@as(usize, 1), channels.len);
    try testing.expectEqual(agents_cfg.ChannelKind.telegram, channels[0].kind);
    try testing.expectEqualStrings("tobi374758_bot", channels[0].account);
    try testing.expectEqualStrings("TIGERCLAW_TG_TOKEN", channels[0].token_env.?);
}
