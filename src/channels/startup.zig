//! Channel startup — walks the agent registry at gateway boot, opens
//! one live channel per agent, and registers it with the manager.
//!
//! Today this handles the Telegram channel only (the only real channel
//! kind v3 has). CLI is stdin-bound and never needs this wiring. New
//! channel kinds (Slack, Discord, …) extend the switch in `bindOne`.
//!
//! # Ownership
//!
//! The glue allocates one `ConcreteChannel` per agent on the heap.
//! Lifetimes are owned by `ChannelTelegram` (this struct) and released via
//! `deinit`. The manager borrows the `spec.Channel` vtable; it does
//! NOT own the underlying struct. That's why the returned
//! `ChannelTelegram` value must outlive the manager, and why `deinit`
//! is mandatory.
//!
//! # Token source
//!
//! Bot tokens are never in config or on disk — each agent's
//! `ChannelRef.token_env` names an environment variable that holds
//! the token. A missing env var is a hard error at boot: silently
//! skipping would hide a misconfiguration until the first inbound
//! poll failed.

const std = @import("std");
const build_options = @import("build_options");

const agents_cfg = @import("../settings/agents.zig");
const registry_mod = @import("../harness/agent_registry.zig");
const manager_mod = @import("manager.zig");
const spec = @import("channels_spec");

const telegram_ext = if (build_options.enable_telegram)
    @import("channel_telegram")
else
    struct {};

pub const Error = error{
    /// A telegram agent was configured but the named env var was
    /// empty or unset. The daemon refuses to start rather than poll
    /// an anonymous endpoint.
    MissingToken,
    /// `getMe` failed against Telegram — token is syntactically
    /// valid but rejected by the API.
    BotHandshakeFailed,
    /// The compiled binary does not include the telegram extension
    /// but a config entry requested it. Rebuild with
    /// `-Dextensions=…,telegram`.
    TelegramDisabled,
    /// Manager rejected the binding (same (agent, channel_id) pair
    /// appeared twice in config).
    DuplicateBinding,
    OutOfMemory,
};

/// A live Telegram channel plus the Bot that backs it. Heap-allocated
/// as a pair so the borrowed pointers inside `TelegramChannel` (which
/// points at `bot`) stay stable for the manager's lifetime.
const TelegramEntry = struct {
    bot: *telegram_ext.api.Bot,
    channel: *telegram_ext.channel.TelegramChannel,
};

/// Collection of channels the gateway holds open for its lifetime.
/// Owns every heap allocation made during `bind`; freeing is the
/// caller's job via `deinit`.
pub const ChannelTelegram = struct {
    allocator: std.mem.Allocator,
    telegram_entries: std.ArrayList(TelegramEntry),

    pub fn init(allocator: std.mem.Allocator) ChannelTelegram {
        return .{
            .allocator = allocator,
            .telegram_entries = .empty,
        };
    }

    /// Release every bot and channel we allocated. Safe to call on a
    /// value that never successfully `bind`-ed anything.
    pub fn deinit(self: *ChannelTelegram) void {
        for (self.telegram_entries.items) |e| {
            // TelegramChannel has no deinit — the vtable.deinit is a
            // no-op and the struct has no owned buffers. Keep the
            // destroy calls for the heap allocations we made.
            self.allocator.destroy(e.channel);
            e.bot.deinit();
            self.allocator.destroy(e.bot);
        }
        self.telegram_entries.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Iterate `registry.entries`, bind every enabled agent's configured
/// channel, and register it on the manager. Returns the `ChannelTelegram`
/// collection so the caller can keep it alive until shutdown. On any
/// error the collection is deinit-ed for the caller.
pub fn bind(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const registry_mod.Registry,
    manager: *manager_mod.Manager,
    log_writer: ?*std.Io.Writer,
) Error!ChannelTelegram {
    var channels = ChannelTelegram.init(allocator);
    errdefer channels.deinit();

    for (registry.entries) |agent| {
        if (!agent.enabled) continue;
        switch (agent.channel.kind) {
            .cli => continue, // CLI channel is stdin-bound; no manager registration
            .telegram => try bindTelegram(&channels, io, agent, manager, log_writer),
        }
    }

    return channels;
}

fn bindTelegram(
    channels: *ChannelTelegram,
    io: std.Io,
    agent: registry_mod.Agent,
    manager: *manager_mod.Manager,
    log_writer: ?*std.Io.Writer,
) Error!void {
    if (comptime !build_options.enable_telegram) {
        return error.TelegramDisabled;
    }

    // Prefer the inline token from the workspace agent.json. Fall
    // back to the named env var for CI-style deployments where the
    // secret lives in the process environment, not on disk.
    const token: []const u8 = blk: {
        if (agent.channel.token) |t| {
            if (t.len > 0) break :blk t;
        }
        const env_name = agent.channel.token_env orelse return error.MissingToken;

        var name_buf: [128]u8 = undefined;
        if (env_name.len >= name_buf.len) return error.MissingToken;
        @memcpy(name_buf[0..env_name.len], env_name);
        name_buf[env_name.len] = 0;
        const name_z: [*:0]const u8 = @ptrCast(&name_buf);

        const raw = std.c.getenv(name_z) orelse return error.MissingToken;
        const from_env = std.mem.span(raw);
        if (from_env.len == 0) return error.MissingToken;
        break :blk from_env;
    };

    const bot = try channels.allocator.create(telegram_ext.api.Bot);
    errdefer channels.allocator.destroy(bot);
    bot.* = .{
        .allocator = channels.allocator,
        .io = io,
        .token = token,
    };

    // Handshake — if the token is bogus we find out at boot rather
    // than on the first poll 30 seconds later. Also auto-clears any
    // webhook so getUpdates won't 409.
    bot.deleteWebhookKeepPending() catch return error.BotHandshakeFailed;
    const identity = bot.getMe() catch return error.BotHandshakeFailed;
    defer identity.deinit(channels.allocator);

    if (log_writer) |w| {
        w.print(
            "telegram: {s} bound to @{s} (bot_id={d}, account={s})\n",
            .{ agent.name, identity.username, identity.id, agent.channel.account },
        ) catch {};
    }

    const tg = try channels.allocator.create(telegram_ext.channel.TelegramChannel);
    errdefer channels.allocator.destroy(tg);
    tg.* = telegram_ext.channel.TelegramChannel.init(channels.allocator, bot);

    manager.add(agent.name, tg.channel()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateBinding => return error.DuplicateBinding,
    };

    channels.telegram_entries.append(channels.allocator, .{ .bot = bot, .channel = tg }) catch return error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const dispatch_mod = @import("dispatch.zig");

test "bind: agent with kind=cli is skipped (no telegram registration)" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 4);
    defer dispatch.deinit();

    var mgr = manager_mod.Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    const entries = [_]registry_mod.Agent{
        .{
            .name = "cli-agent",
            .persona = "",
            .provider = "mock",
            .model = "mock",
            .monthly_budget_cents = 0,
            .enabled = true,
            .channel = .{ .kind = .cli, .account = "stdin", .token_env = null },
        },
    };

    // Registry can't be built directly — fake one via the internal
    // struct layout. This is only valid for a read-only iteration.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const registry: registry_mod.Registry = .{
        .arena = arena,
        .entries = @constCast(&entries),
        .default_name = "cli-agent",
    };

    var channels = try bind(testing.allocator, testing.io, &registry, &mgr, null);
    defer channels.deinit();

    try testing.expectEqual(@as(usize, 0), channels.telegram_entries.items.len);
    try testing.expect(mgr.get("cli-agent", .telegram) == null);
}

test "bind: telegram agent with missing token env → MissingToken" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 4);
    defer dispatch.deinit();

    var mgr = manager_mod.Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    const entries = [_]registry_mod.Agent{
        .{
            .name = "tiger",
            .persona = "",
            .provider = "mock",
            .model = "mock",
            .monthly_budget_cents = 0,
            .enabled = true,
            .channel = .{
                .kind = .telegram,
                .account = "tobi374758_bot",
                // Pick a name that almost certainly isn't set in the
                // test environment. If a CI box does set it, rename.
                .token_env = "TIGERCLAW_DEFINITELY_UNSET_FOR_TESTS",
            },
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const registry: registry_mod.Registry = .{
        .arena = arena,
        .entries = @constCast(&entries),
        .default_name = "tiger",
    };

    try testing.expectError(
        error.MissingToken,
        bind(testing.allocator, testing.io, &registry, &mgr, null),
    );
}
