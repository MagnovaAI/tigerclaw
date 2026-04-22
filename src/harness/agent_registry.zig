//! Agent registry — the loaded set of agents the gateway hosts.
//!
//! The gateway boots with an `agents:` block validated by
//! `settings.agents`. The registry lifts that config into runtime
//! state: an owned array of `Agent` entries plus the key → entry map
//! handlers consult to route a turn.
//!
//! This commit does *not* spin up per-agent threads or runners — that
//! lands alongside the channel manager. The registry here is pure
//! state: name lookup, session path derivation, and the `default`
//! selector used when `--agent` is omitted.

const std = @import("std");
const agents_cfg = @import("../settings/agents.zig");

pub const Agent = struct {
    /// Unique agent name (matches `AgentConfig.name`). Owned by the
    /// registry's arena.
    name: []const u8,
    persona: []const u8,
    provider: []const u8,
    model: []const u8,
    monthly_budget_cents: u64,
    enabled: bool,
    /// Snapshot of the agent's (single, in v0.1.0) channel ref.
    channel: agents_cfg.ChannelRef,
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Agent,
    /// Name of the default agent as declared in config. Empty when
    /// the config had zero agents.
    default_name: []const u8,

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    /// Look up an agent by name. Returns null when no match.
    pub fn find(self: *const Registry, name: []const u8) ?*const Agent {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// Resolve the agent selected by `--agent <name>`; falls back to
    /// the configured `default_name` when `name_opt` is null. Returns
    /// null when neither is set or the name is unknown.
    pub fn resolveSelector(self: *const Registry, name_opt: ?[]const u8) ?*const Agent {
        const name = name_opt orelse self.default_name;
        if (name.len == 0) return null;
        return self.find(name);
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.len;
    }
};

pub const BuildError = error{
    OutOfMemory,
    ValidationFailed,
};

/// Build a `Registry` from a validated `AgentsConfig`. The caller
/// owns the returned value and must call `deinit`. All borrowed
/// strings in the input are duplicated into the registry's arena so
/// the config struct can be freed independently.
pub fn build(
    allocator: std.mem.Allocator,
    cfg: agents_cfg.AgentsConfig,
) BuildError!Registry {
    if (agents_cfg.validate(cfg) != null) return error.ValidationFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const entries = try aa.alloc(Agent, cfg.entries.len);
    for (cfg.entries, 0..) |src, i| {
        const ch = src.channels[0];
        entries[i] = .{
            .name = try aa.dupe(u8, src.name),
            .persona = try aa.dupe(u8, src.persona),
            .provider = try aa.dupe(u8, src.provider),
            .model = try aa.dupe(u8, src.model),
            .monthly_budget_cents = src.monthly_budget_cents,
            .enabled = src.enabled,
            .channel = .{
                .kind = ch.kind,
                .account = try aa.dupe(u8, ch.account),
                .token_env = if (ch.token_env) |t| try aa.dupe(u8, t) else null,
            },
        };
    }

    return .{
        .arena = arena,
        .entries = entries,
        .default_name = if (entries.len > 0) try aa.dupe(u8, cfg.default) else "",
    };
}

// --- session paths ---------------------------------------------------------

pub const SessionKey = struct {
    agent_name: []const u8,
    channel_id: []const u8,
    conversation_key: []const u8,
};

/// Derive the on-disk session path for a given key, relative to a
/// sessions root directory (typically `$XDG_CONFIG_HOME/tigerclaw/sessions`).
/// Layout: `sessions/<agent>/<channel>/<key>.json`. The caller owns
/// the returned allocation.
pub fn derivePath(
    allocator: std.mem.Allocator,
    root: []const u8,
    key: SessionKey,
) std.mem.Allocator.Error![]u8 {
    var filename_buf = std.array_list.Managed(u8).init(allocator);
    defer filename_buf.deinit();
    try filename_buf.appendSlice(key.conversation_key);
    try filename_buf.appendSlice(".json");

    return std.fs.path.join(
        allocator,
        &.{ root, key.agent_name, key.channel_id, filename_buf.items },
    );
}

pub const url_safe_error = error{UrlUnsafe};

/// Reject path components that would escape the session directory or
/// embed control/path characters. This is a small allowlist: letters,
/// digits, `-`, `_`, `.`, and must not start with `.`. The router
/// uses this for every segment of a `SessionKey` before deriving a
/// path.
pub fn requireUrlSafe(component: []const u8) url_safe_error!void {
    if (component.len == 0) return error.UrlUnsafe;
    if (component[0] == '.') return error.UrlUnsafe;
    for (component) |c| {
        const ok =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        if (!ok) return error.UrlUnsafe;
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const cli_channels = [_]agents_cfg.ChannelRef{
    .{ .kind = .cli, .account = "stdin" },
};
const tg_channels = [_]agents_cfg.ChannelRef{
    .{ .kind = .telegram, .account = "bot", .token_env = "TG" },
};

fn makeSimpleConfig() agents_cfg.AgentsConfig {
    const entries = comptime [_]agents_cfg.AgentConfig{
        .{ .name = "cli", .channels = &cli_channels },
        .{
            .name = "concierge",
            .provider = "anthropic",
            .model = "claude-3-sonnet",
            .channels = &tg_channels,
        },
    };
    return .{ .default = "cli", .entries = &entries };
}

test "build: lifts a validated config into an owned Registry" {
    var reg = try build(testing.allocator, makeSimpleConfig());
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expectEqualStrings("cli", reg.default_name);

    const cli_agent = reg.find("cli").?;
    try testing.expectEqual(agents_cfg.ChannelKind.cli, cli_agent.channel.kind);

    const concierge = reg.find("concierge").?;
    try testing.expectEqualStrings("anthropic", concierge.provider);
    try testing.expectEqualStrings("TG", concierge.channel.token_env.?);
}

test "build: returns ValidationFailed for an invalid config" {
    const channels = [_]agents_cfg.ChannelRef{.{ .kind = .cli, .account = "stdin" }};
    const entries = [_]agents_cfg.AgentConfig{.{ .name = "", .channels = &channels }};
    const cfg: agents_cfg.AgentsConfig = .{ .entries = &entries, .default = "" };
    try testing.expectError(error.ValidationFailed, build(testing.allocator, cfg));
}

test "resolveSelector: explicit name wins over default" {
    var reg = try build(testing.allocator, makeSimpleConfig());
    defer reg.deinit();

    const chosen = reg.resolveSelector("concierge").?;
    try testing.expectEqualStrings("concierge", chosen.name);
}

test "resolveSelector: null falls back to the default agent" {
    var reg = try build(testing.allocator, makeSimpleConfig());
    defer reg.deinit();

    const chosen = reg.resolveSelector(null).?;
    try testing.expectEqualStrings("cli", chosen.name);
}

test "resolveSelector: unknown name returns null" {
    var reg = try build(testing.allocator, makeSimpleConfig());
    defer reg.deinit();

    try testing.expect(reg.resolveSelector("ghost") == null);
}

test "derivePath: builds sessions/<agent>/<channel>/<key>.json" {
    const path = try derivePath(testing.allocator, "/var/tigerclaw/sessions", .{
        .agent_name = "concierge",
        .channel_id = "telegram-bot",
        .conversation_key = "chat-42",
    });
    defer testing.allocator.free(path);

    const expected = "/var/tigerclaw/sessions/concierge/telegram-bot/chat-42.json";
    try testing.expectEqualStrings(expected, path);
}

test "requireUrlSafe: accepts simple alphanumerics and hyphen" {
    try requireUrlSafe("concierge");
    try requireUrlSafe("chat-42");
    try requireUrlSafe("telegram_bot-99");
}

test "requireUrlSafe: rejects empty, dot-prefixed, and control characters" {
    try testing.expectError(error.UrlUnsafe, requireUrlSafe(""));
    try testing.expectError(error.UrlUnsafe, requireUrlSafe(".hidden"));
    try testing.expectError(error.UrlUnsafe, requireUrlSafe("../escape"));
    try testing.expectError(error.UrlUnsafe, requireUrlSafe("with space"));
    try testing.expectError(error.UrlUnsafe, requireUrlSafe("with/slash"));
}
