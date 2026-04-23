//! AgentRunner that calls the real Anthropic provider.
//!
//! Loads the API key from `~/.tigerclaw/config.json`, the agent's
//! system prompt from `~/.tigerclaw/agents/<name>/SOUL.md` (when
//! present), and streams a synchronous chat through `AnthropicProvider.http`
//! on every `run()` call. The result is buffered into a slice the runner
//! owns until the next call — single-threaded gateway means the handler
//! finishes consuming `result.output` before the next `run()` rotates
//! the buffer.
//!
//! Token budget enforcement, multi-turn history, tool use, and real
//! per-token streaming are explicit non-goals for v0.1.0; the gateway
//! treats every turn as a fresh user→assistant round-trip.

const std = @import("std");
const harness = @import("../../harness/root.zig");
const llm = @import("../../llm/root.zig");
const types = @import("types");

pub const LoadError = error{
    HomeMissing,
    ConfigMissing,
    ConfigParseFailed,
    ApiKeyMissing,
    AgentMissing,
    AgentParseFailed,
    UnknownProvider,
} || std.mem.Allocator.Error;

pub const RunError = harness.agent_runner.TurnError;

pub const ProviderKind = enum { anthropic, openai, openrouter };

pub const LiveAgentRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    in_flight: harness.agent_runner.InFlightCounter,

    /// Long-lived state owned by the runner so the vtable's
    /// fixed-shape callback signature has somewhere to stash strings
    /// across handler invocations.
    provider_kind: ProviderKind,
    api_key: []u8,
    model: []u8,
    system_prompt: ?[]u8 = null,
    /// The most recent run's output. Borrowed by the route handler
    /// for the duration of the request; rotated on the next run().
    last_output: []u8 = &.{},

    pub fn loadFromHome(
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_name: []const u8,
        home: []const u8,
    ) LoadError!LiveAgentRunner {
        if (home.len == 0) return error.HomeMissing;

        // Load the agent's manifest first so we know which provider
        // key to pluck out of config.json.
        var agent_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const agent_json_path = std.fmt.bufPrint(&agent_path_buf, "{s}/.tigerclaw/agents/{s}/agent.json", .{ home, agent_name }) catch
            return error.AgentMissing;
        const agent_bytes = std.Io.Dir.cwd().readFileAlloc(io, agent_json_path, allocator, .limited(16 * 1024)) catch
            return error.AgentMissing;
        defer allocator.free(agent_bytes);

        const manifest = try parseAgentManifest(allocator, agent_bytes);
        errdefer allocator.free(manifest.model);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_path = std.fmt.bufPrint(&path_buf, "{s}/.tigerclaw/config.json", .{home}) catch
            return error.ConfigMissing;

        const config_bytes = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(64 * 1024)) catch
            return error.ConfigMissing;
        defer allocator.free(config_bytes);

        const api_key = try parseProviderKey(allocator, config_bytes, manifest.provider);

        // SOUL.md is optional — many agents won't have one yet.
        var soul_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const soul_path = std.fmt.bufPrint(&soul_path_buf, "{s}/.tigerclaw/agents/{s}/SOUL.md", .{ home, agent_name }) catch
            return error.AgentMissing;
        const soul = std.Io.Dir.cwd().readFileAlloc(io, soul_path, allocator, .limited(32 * 1024)) catch null;

        return .{
            .allocator = allocator,
            .io = io,
            .in_flight = harness.agent_runner.InFlightCounter.init(),
            .provider_kind = manifest.provider,
            .api_key = api_key,
            .model = manifest.model,
            .system_prompt = soul,
        };
    }

    pub fn deinit(self: *LiveAgentRunner) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        if (self.system_prompt) |s| self.allocator.free(s);
        if (self.last_output.len > 0) self.allocator.free(self.last_output);
        self.* = undefined;
    }

    pub fn runner(self: *LiveAgentRunner) harness.agent_runner.AgentRunner {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: harness.agent_runner.VTable = .{
        .run = liveRun,
        .cancel = liveCancel,
        .counter = liveCounter,
    };

    fn liveCounter(ctx: *anyopaque) *harness.agent_runner.InFlightCounter {
        const self: *LiveAgentRunner = @ptrCast(@alignCast(ctx));
        return &self.in_flight;
    }

    fn liveCancel(_: *anyopaque, _: harness.agent_runner.TurnId) void {
        // v0.1.0 has no in-process cancellation hook through the
        // provider; the next run after the cancel just doesn't get
        // sent. Real cooperative cancel lands with the streaming
        // dispatcher in v0.2.0.
    }

    fn liveRun(
        ctx: *anyopaque,
        req: harness.agent_runner.TurnRequest,
    ) harness.agent_runner.TurnError!harness.agent_runner.TurnResult {
        const self: *LiveAgentRunner = @ptrCast(@alignCast(ctx));
        self.in_flight.begin();
        defer self.in_flight.end();

        if (req.session_id.len == 0) return error.SessionMissing;

        // Rotate the output buffer. The handler that consumed the
        // previous result has long since written it to the wire by
        // the time we land here for the next turn.
        if (self.last_output.len > 0) {
            self.allocator.free(self.last_output);
            self.last_output = &.{};
        }

        // Build the right provider for this agent. The HTTP client is
        // owned by the provider for the duration of one chat call, so
        // per-turn construction is the simplest correct shape.
        const config: llm.ProviderConfig = switch (self.provider_kind) {
            .anthropic => .{ .anthropic = .{
                .io = self.io,
                .api_key = self.api_key,
                .beta_features = if (std.mem.startsWith(u8, self.api_key, "sk-ant-oat01-"))
                    "oauth-2025-04-20"
                else
                    null,
            } },
            .openai => .{ .openai = .{
                .io = self.io,
                .api_key = self.api_key,
            } },
            .openrouter => .{ .openrouter = .{
                .io = self.io,
                .api_key = self.api_key,
            } },
        };
        var owned = llm.fromSettings(self.allocator, config) catch return error.InternalError;
        defer owned.deinit(self.allocator);

        const messages = [_]types.Message{
            .{ .role = .user, .content = req.input },
        };

        const chat_req: llm.provider.ChatRequest = .{
            .messages = &messages,
            .model = .{ .provider = @tagName(self.provider_kind), .model = self.model },
            .system = self.system_prompt,
            .max_output_tokens = 1024,
        };

        const resp = owned.provider.chat(self.allocator, chat_req) catch
            return error.InternalError;
        defer if (resp.text) |t| self.allocator.free(t);

        const text = resp.text orelse "";
        // Take ownership of the response text so the handler can borrow
        // it past the provider's lifetime.
        self.last_output = self.allocator.dupe(u8, text) catch return error.OutOfMemory;

        return .{ .output = self.last_output, .completed = resp.stop_reason != .refusal };
    }
};

/// Parsed agent manifest. `model` is heap-allocated; caller owns.
const AgentManifest = struct {
    provider: ProviderKind,
    model: []u8,
};

/// Parse `agent.json` for the agent's provider + model.
fn parseAgentManifest(allocator: std.mem.Allocator, bytes: []const u8) LoadError!AgentManifest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.AgentParseFailed;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.AgentParseFailed;
    const provider_v = root.object.get("provider") orelse return error.AgentParseFailed;
    if (provider_v != .string) return error.AgentParseFailed;
    const kind = std.meta.stringToEnum(ProviderKind, provider_v.string) orelse return error.UnknownProvider;

    const model_v = root.object.get("model") orelse return error.AgentParseFailed;
    if (model_v != .string) return error.AgentParseFailed;
    const model = try allocator.dupe(u8, model_v.string);

    return .{ .provider = kind, .model = model };
}

/// Parse `models.providers.<name>.api_key` out of the config JSON.
/// Returns an owned slice the caller frees.
fn parseProviderKey(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    provider: ProviderKind,
) LoadError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.ConfigParseFailed;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.ConfigParseFailed;
    const models = root.object.get("models") orelse return error.ApiKeyMissing;
    if (models != .object) return error.ConfigParseFailed;
    const providers_v = models.object.get("providers") orelse return error.ApiKeyMissing;
    if (providers_v != .object) return error.ConfigParseFailed;
    const node = providers_v.object.get(@tagName(provider)) orelse return error.ApiKeyMissing;
    if (node != .object) return error.ConfigParseFailed;
    const key_value = node.object.get("api_key") orelse return error.ApiKeyMissing;
    if (key_value != .string) return error.ConfigParseFailed;
    return try allocator.dupe(u8, key_value.string);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseProviderKey: extracts anthropic key from a canonical config" {
    const json =
        \\{"models":{"providers":{"anthropic":{"api_key":"sk-test-123"}}}}
    ;
    const k = try parseProviderKey(testing.allocator, json, .anthropic);
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("sk-test-123", k);
}

test "parseProviderKey: extracts openai key" {
    const json =
        \\{"models":{"providers":{"openai":{"api_key":"sk-oai-x"}}}}
    ;
    const k = try parseProviderKey(testing.allocator, json, .openai);
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("sk-oai-x", k);
}

test "parseProviderKey: missing block returns ApiKeyMissing" {
    const json =
        \\{"models":{"providers":{"openai":{"api_key":"sk-x"}}}}
    ;
    try testing.expectError(error.ApiKeyMissing, parseProviderKey(testing.allocator, json, .anthropic));
}

test "parseProviderKey: malformed JSON returns ConfigParseFailed" {
    const json = "{not json";
    try testing.expectError(error.ConfigParseFailed, parseProviderKey(testing.allocator, json, .anthropic));
}

test "parseAgentManifest: extracts provider + model" {
    const json =
        \\{"name":"sage","provider":"openai","model":"gpt-4o-mini"}
    ;
    const m = try parseAgentManifest(testing.allocator, json);
    defer testing.allocator.free(m.model);
    try testing.expectEqual(ProviderKind.openai, m.provider);
    try testing.expectEqualStrings("gpt-4o-mini", m.model);
}

test "parseAgentManifest: unknown provider rejects" {
    const json =
        \\{"provider":"made-up","model":"x"}
    ;
    try testing.expectError(error.UnknownProvider, parseAgentManifest(testing.allocator, json));
}
