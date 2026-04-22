//! Agents config block — plumbing for the multi-agent harness.
//!
//! Rule (v0.1.0): one channel account = one agent. Each gateway hosts
//! N agents; each agent owns exactly one channel account, its own
//! persona, provider, model, budget, and session store.
//!
//! This module defines the JSON-parseable shape of that block and a
//! validator that enforces the 1:1 channel rule. Impl wiring (loader,
//! registry, per-agent threads) lands in later commits. The schema
//! itself is array-shaped (`channels: [ChannelRef]`) so v0.2.0 can flip
//! the validator to allow `len >= 1` without touching anything else.
//!
//! The `memory` block is also parsed here but has no v0.1.0 behaviour:
//! it reserves the shape so the v0.2.0 memory subsystem can land
//! without schema churn.

const std = @import("std");

pub const ChannelKind = enum {
    cli,
    telegram,

    pub fn jsonStringify(self: ChannelKind, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ChannelKind {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(ChannelKind, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const ChannelRef = struct {
    kind: ChannelKind,
    /// Channel account identifier. For `telegram` this is the bot
    /// username; for `cli` it is fixed to `"stdin"`. The validator
    /// enforces non-empty.
    account: []const u8 = "",
    /// Environment variable name that holds the channel credential.
    /// Optional for `cli`; required for real channels.
    token_env: ?[]const u8 = null,
};

pub const MemoryConfig = struct {
    /// When true the agent has a private `own` memory store. v0.1.0
    /// parses this but the backing store is not yet implemented.
    own: bool = true,
    /// Team scopes the agent belongs to. Empty = none.
    teams: []const []const u8 = &.{},
    /// Gate on writing to the global `all` scope. Only agents that
    /// explicitly opt-in may broadcast.
    can_write_all: bool = false,
};

pub const AgentConfig = struct {
    name: []const u8,
    persona: []const u8 = "",
    provider: []const u8 = "mock",
    model: []const u8 = "mock-sonnet",
    /// Hard monthly cap (cents). Zero means "inherit default".
    monthly_budget_cents: u64 = 0,
    enabled: bool = true,
    /// v0.1.0 validator enforces `len == 1`; v0.2.0 flips to
    /// `len >= 1`. Keeping the field as an array from day one is
    /// deliberate plumbing.
    channels: []const ChannelRef = &.{},
    memory: MemoryConfig = .{},
};

pub const AgentsConfig = struct {
    /// Agent selected when `tigerclaw agent` is invoked without
    /// `--agent <name>`. Must be a known agent name; the validator
    /// enforces this only when at least one agent is configured.
    default: []const u8 = "cli",
    /// All configured agents. The validator enforces name uniqueness.
    entries: []const AgentConfig = &.{},
};

pub const ValidationError = error{
    EmptyAgentName,
    DuplicateAgentName,
    AgentHasZeroChannels,
    AgentHasMultipleChannels,
    ChannelMissingAccount,
    ChannelMissingTokenEnv,
    DefaultAgentUnknown,
};

pub const ValidationResult = struct {
    err: ValidationError,
    agent_index: usize,
};

pub const validation_ok: ?ValidationResult = null;

/// Validate an `AgentsConfig` against the v0.1.0 rules. Returns null
/// on success; otherwise the first error encountered along with the
/// offending agent index. The caller can emit a precise message by
/// combining the error tag with `cfg.entries[agent_index].name`.
pub fn validate(cfg: AgentsConfig) ?ValidationResult {
    for (cfg.entries, 0..) |agent, i| {
        if (agent.name.len == 0) {
            return .{ .err = ValidationError.EmptyAgentName, .agent_index = i };
        }

        // Name uniqueness.
        for (cfg.entries[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, agent.name)) {
                return .{ .err = ValidationError.DuplicateAgentName, .agent_index = i };
            }
        }

        if (agent.channels.len == 0) {
            return .{ .err = ValidationError.AgentHasZeroChannels, .agent_index = i };
        }
        if (agent.channels.len > 1) {
            return .{ .err = ValidationError.AgentHasMultipleChannels, .agent_index = i };
        }

        const ch = agent.channels[0];
        if (ch.account.len == 0) {
            return .{ .err = ValidationError.ChannelMissingAccount, .agent_index = i };
        }
        if (ch.kind != .cli and ch.token_env == null) {
            return .{ .err = ValidationError.ChannelMissingTokenEnv, .agent_index = i };
        }
    }

    if (cfg.entries.len > 0) {
        var found = false;
        for (cfg.entries) |agent| {
            if (std.mem.eql(u8, agent.name, cfg.default)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return .{ .err = ValidationError.DefaultAgentUnknown, .agent_index = 0 };
        }
    }

    return validation_ok;
}

/// Convenience: the default single-agent config seeded during
/// `tigerclaw setup` so first-run works. One `cli` agent reading
/// from stdin with the mock provider.
pub fn defaultAgents() AgentsConfig {
    const channels = comptime [_]ChannelRef{
        .{ .kind = .cli, .account = "stdin" },
    };
    const entries = comptime [_]AgentConfig{
        .{ .name = "cli", .channels = &channels },
    };
    return .{ .entries = &entries };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "defaultAgents: validates cleanly" {
    try testing.expectEqual(@as(?ValidationResult, null), validate(defaultAgents()));
}

test "validate: rejects an agent with an empty name" {
    const channels = [_]ChannelRef{.{ .kind = .cli, .account = "stdin" }};
    const entries = [_]AgentConfig{.{ .name = "", .channels = &channels }};
    const res = validate(.{ .entries = &entries, .default = "" }).?;
    try testing.expectEqual(ValidationError.EmptyAgentName, res.err);
    try testing.expectEqual(@as(usize, 0), res.agent_index);
}

test "validate: rejects duplicate agent names" {
    const channels = [_]ChannelRef{.{ .kind = .cli, .account = "stdin" }};
    const entries = [_]AgentConfig{
        .{ .name = "cli", .channels = &channels },
        .{ .name = "cli", .channels = &channels },
    };
    const res = validate(.{ .entries = &entries, .default = "cli" }).?;
    try testing.expectEqual(ValidationError.DuplicateAgentName, res.err);
    try testing.expectEqual(@as(usize, 1), res.agent_index);
}

test "validate: rejects zero-channel agent" {
    const entries = [_]AgentConfig{.{ .name = "cli" }};
    const res = validate(.{ .entries = &entries, .default = "cli" }).?;
    try testing.expectEqual(ValidationError.AgentHasZeroChannels, res.err);
}

test "validate: rejects multi-channel agent in v0.1.0" {
    const channels = [_]ChannelRef{
        .{ .kind = .cli, .account = "stdin" },
        .{ .kind = .telegram, .account = "bot", .token_env = "TG" },
    };
    const entries = [_]AgentConfig{.{ .name = "cli", .channels = &channels }};
    const res = validate(.{ .entries = &entries, .default = "cli" }).?;
    try testing.expectEqual(ValidationError.AgentHasMultipleChannels, res.err);
}

test "validate: rejects real channel without token_env" {
    const channels = [_]ChannelRef{.{ .kind = .telegram, .account = "bot" }};
    const entries = [_]AgentConfig{.{ .name = "tg", .channels = &channels }};
    const res = validate(.{ .entries = &entries, .default = "tg" }).?;
    try testing.expectEqual(ValidationError.ChannelMissingTokenEnv, res.err);
}

test "validate: rejects channel with empty account" {
    const channels = [_]ChannelRef{.{ .kind = .cli, .account = "" }};
    const entries = [_]AgentConfig{.{ .name = "cli", .channels = &channels }};
    const res = validate(.{ .entries = &entries, .default = "cli" }).?;
    try testing.expectEqual(ValidationError.ChannelMissingAccount, res.err);
}

test "validate: rejects agents.default that names no configured agent" {
    const channels = [_]ChannelRef{.{ .kind = .cli, .account = "stdin" }};
    const entries = [_]AgentConfig{.{ .name = "cli", .channels = &channels }};
    const res = validate(.{ .entries = &entries, .default = "ghost" }).?;
    try testing.expectEqual(ValidationError.DefaultAgentUnknown, res.err);
}

test "validate: empty agent list is allowed (no default required)" {
    try testing.expectEqual(@as(?ValidationResult, null), validate(.{}));
}

test "AgentsConfig: JSON roundtrip preserves structure" {
    const channels = [_]ChannelRef{
        .{ .kind = .telegram, .account = "tigerclawbot", .token_env = "TIGERCLAW_TG_TOKEN" },
    };
    const entries = [_]AgentConfig{
        .{
            .name = "concierge",
            .persona = "friendly",
            .provider = "anthropic",
            .model = "claude-3-sonnet",
            .monthly_budget_cents = 5_00,
            .channels = &channels,
            .memory = .{ .own = true, .can_write_all = false },
        },
    };
    const cfg: AgentsConfig = .{ .default = "concierge", .entries = &entries };

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, cfg, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(AgentsConfig, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("concierge", parsed.value.default);
    try testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    const a = parsed.value.entries[0];
    try testing.expectEqualStrings("concierge", a.name);
    try testing.expectEqualStrings("anthropic", a.provider);
    try testing.expectEqual(@as(u64, 5_00), a.monthly_budget_cents);
    try testing.expectEqual(@as(usize, 1), a.channels.len);
    try testing.expectEqual(ChannelKind.telegram, a.channels[0].kind);
    try testing.expectEqualStrings("tigerclawbot", a.channels[0].account);
    try testing.expect(a.channels[0].token_env != null);
    try testing.expectEqualStrings("TIGERCLAW_TG_TOKEN", a.channels[0].token_env.?);
    try testing.expect(!a.memory.can_write_all);
}
