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
//! Multi-turn history is provided by an in-process `DefaultEngine` from
//! the context subsystem, keyed by `req.session_id`. Tool use and real
//! per-token streaming remain non-goals for v0.1.0.

const std = @import("std");
const harness = @import("../../harness/root.zig");
const llm = @import("../../llm/root.zig");
const types = @import("types");
const clock_mod = @import("clock");
const context_mod = @import("context");
const context_root = @import("ctx_root");

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

    /// Multi-turn history store. Keyed by `TurnRequest.session_id`;
    /// each run ingests the user message, assembles the context
    /// window from prior turns, then ingests the assistant reply.
    context_engine: *context_root.default_engine.DefaultEngine,
    /// Wall clock for the `Context` bundle handed to engine methods.
    system_clock: clock_mod.SystemClock = .{},
    /// Monotonic counter feeding unique `message_id`s into ingest.
    /// Ingest is idempotent on (session_id, message_id) so collisions
    /// silently drop the duplicate — we avoid that with a counter.
    next_message_id: u64 = 0,

    /// Load an agent config with workspace-then-global cascade.
    /// For each file (agent.json, config.json, SOUL.md) tries
    /// `<workspace>/.tigerclaw/…` first, falls back to
    /// `<home>/.tigerclaw/…`. Either may be empty to skip its side.
    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_name: []const u8,
        workspace: []const u8,
        home: []const u8,
    ) LoadError!LiveAgentRunner {
        if (workspace.len == 0 and home.len == 0) return error.HomeMissing;

        // agent.json: workspace wins, fall back to home.
        const agent_bytes = try readCascade(
            allocator,
            io,
            workspace,
            home,
            "agents",
            agent_name,
            "agent.json",
            .limited(16 * 1024),
            error.AgentMissing,
        );
        defer allocator.free(agent_bytes);

        const manifest = try parseAgentManifest(allocator, agent_bytes);
        errdefer allocator.free(manifest.model);

        // config.json: same cascade — lets an operator pin per-project
        // provider keys without editing the global file.
        const config_bytes = try readRootCascade(
            allocator,
            io,
            workspace,
            home,
            "config.json",
            .limited(64 * 1024),
            error.ConfigMissing,
        );
        defer allocator.free(config_bytes);

        const api_key = try parseProviderKey(allocator, config_bytes, manifest.provider);

        // SOUL.md is optional at both layers.
        const soul = readCascade(
            allocator,
            io,
            workspace,
            home,
            "agents",
            agent_name,
            "SOUL.md",
            .limited(32 * 1024),
            error.AgentMissing,
        ) catch null;

        const engine = try context_root.default_engine.DefaultEngine.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .in_flight = harness.agent_runner.InFlightCounter.init(),
            .provider_kind = manifest.provider,
            .api_key = api_key,
            .model = manifest.model,
            .system_prompt = soul,
            .context_engine = engine,
        };
    }

    /// Back-compat shim — prefer `load(..., workspace, home)`.
    pub fn loadFromHome(
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_name: []const u8,
        home: []const u8,
    ) LoadError!LiveAgentRunner {
        return load(allocator, io, agent_name, "", home);
    }

    pub fn deinit(self: *LiveAgentRunner) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        if (self.system_prompt) |s| self.allocator.free(s);
        if (self.last_output.len > 0) self.allocator.free(self.last_output);
        self.context_engine.deinit();
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

        // Build the context bundle engine methods expect. The default
        // in-memory engine ignores most fields; only `alloc` and
        // `session_id` carry meaning today.
        const clock_value = self.system_clock.clock();
        const context_bundle = context_mod.Context{
            .io = undefined,
            .alloc = self.allocator,
            .clock = &clock_value,
            .trace_id = std.mem.zeroes(context_mod.TraceId),
            .parent_span_id = null,
            .deadline_ms = null,
            .budget = null,
            .principal = "user:unknown",
            .session_id = req.session_id,
            .origin_channel_id = null,
        };

        // Record the incoming user message before assembling so it
        // shows up as the final user turn in the history section list.
        const user_msg_id = try self.nextMessageId();
        defer self.allocator.free(user_msg_id);
        _ = self.context_engine.engine().vtable.ingest(
            &context_bundle,
            self.context_engine.engine().ptr,
            .{
                .session_id = req.session_id,
                .message_id = user_msg_id,
                .role = .user,
                .content = req.input,
            },
        ) catch return error.InternalError;

        // Assemble the context window. The default engine also emits
        // a `current_prompt` section for `prompt`; we drop it during
        // conversion because the user message is already in history.
        const assembled = self.context_engine.engine().vtable.assemble(
            &context_bundle,
            self.context_engine.engine().ptr,
            .{
                .session_id = req.session_id,
                .prompt = req.input,
                .model = self.model,
                .available_tools = &.{},
                .token_budget = 64 * 1024,
            },
        ) catch return error.InternalError;
        defer self.context_engine.freeAssembleResult(assembled);

        var messages: std.ArrayList(types.Message) = .empty;
        defer messages.deinit(self.allocator);
        try messages.ensureTotalCapacity(self.allocator, assembled.sections.len);
        for (assembled.sections) |section| {
            // `current_prompt` duplicates the user message we just
            // ingested; skip it rather than send the same text twice.
            if (section.kind == .current_prompt) continue;
            messages.appendAssumeCapacity(.{
                .role = mapRole(section.role),
                .content = section.content,
            });
        }

        // Dispatch loop: the model may answer with tool_use instead of
        // a final reply. Execute each tool locally, ingest the
        // assistant + tool messages into history, and call the
        // provider again. Cap the round-trip count so a malformed or
        // persistently tool-using model can't wedge the request.
        const max_tool_rounds: u8 = 3;
        var round: u8 = 0;
        var final_text: []u8 = &.{};
        errdefer self.allocator.free(final_text);
        var last_stop: types.StopReason = .end_turn;

        while (round < max_tool_rounds) : (round += 1) {
            const chat_req: llm.provider.ChatRequest = .{
                .messages = messages.items,
                .model = .{ .provider = @tagName(self.provider_kind), .model = self.model },
                .system = self.system_prompt,
                .max_output_tokens = 1024,
                .tools = &builtin_tools,
            };

            const resp = owned.provider.chat(self.allocator, chat_req) catch
                return error.InternalError;
            defer resp.deinit(self.allocator);
            last_stop = resp.stop_reason;

            const text = resp.text orelse "";

            // Record whatever the assistant said (text and/or the
            // tool-use intent). The default engine only stores the
            // text, so we serialise a concise tool-call marker so the
            // assistant turn is not lost on the next assemble call.
            if (text.len > 0 or resp.tool_calls.len > 0) {
                const marker = try renderAssistantTurn(self.allocator, text, resp.tool_calls);
                defer self.allocator.free(marker);
                const asst_msg_id = try self.nextMessageId();
                defer self.allocator.free(asst_msg_id);
                _ = self.context_engine.engine().vtable.ingest(
                    &context_bundle,
                    self.context_engine.engine().ptr,
                    .{
                        .session_id = req.session_id,
                        .message_id = asst_msg_id,
                        .role = .assistant,
                        .content = marker,
                    },
                ) catch return error.InternalError;
            }

            if (resp.tool_calls.len == 0) {
                self.allocator.free(final_text);
                final_text = try self.allocator.dupe(u8, text);
                break;
            }

            // Execute each tool, ingest the result as a tool-role
            // message, and feed it back on the next round via the
            // assembled messages slice.
            messages.appendAssumeCapacity(.{
                .role = .assistant,
                .content = text,
            });
            for (resp.tool_calls) |tc| {
                const result_text = dispatchBuiltinTool(
                    self.allocator,
                    clock_value,
                    tc.name,
                    tc.arguments_json,
                ) catch |e| blk: {
                    break :blk std.fmt.allocPrint(
                        self.allocator,
                        "tool {s} failed: {s}",
                        .{ tc.name, @errorName(e) },
                    ) catch return error.OutOfMemory;
                };
                defer self.allocator.free(result_text);

                const tool_msg_id = try self.nextMessageId();
                defer self.allocator.free(tool_msg_id);
                _ = self.context_engine.engine().vtable.ingest(
                    &context_bundle,
                    self.context_engine.engine().ptr,
                    .{
                        .session_id = req.session_id,
                        .message_id = tool_msg_id,
                        .role = .tool,
                        .content = result_text,
                    },
                ) catch return error.InternalError;

                // Append to the in-flight message list too — the next
                // `chat()` call sends whatever this slice contains,
                // without re-running assemble. That keeps tool round
                // trips inside one turn.
                try messages.append(self.allocator, .{
                    .role = .tool,
                    .content = try self.allocator.dupe(u8, result_text),
                });
            }
        }

        self.last_output = final_text;
        return .{ .output = self.last_output, .completed = last_stop != .refusal };
    }

    /// Allocate a unique message id of the form `"msg-<counter>"`.
    /// The counter is per-runner rather than per-session because the
    /// engine keys by (session_id, message_id); a global counter
    /// avoids any cross-session collision even if session_ids collide.
    fn nextMessageId(self: *LiveAgentRunner) ![]u8 {
        const id = self.next_message_id;
        self.next_message_id += 1;
        return std.fmt.allocPrint(self.allocator, "msg-{d}", .{id});
    }

    /// Map context-engine Role to the LLM message Role. They are
    /// nominally identical but compile-time separate types.
    fn mapRole(r: context_root.types.Role) types.Role {
        return switch (r) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
            .tool => .tool,
        };
    }
};

/// The tool schemas the runner exposes to every agent. For now this
/// is a hard-coded one-entry list; a real registry is future work.
const builtin_tools = [_]types.Tool{
    .{
        .name = "get_current_time",
        .description = "Return the current date and time as an ISO-8601 UTC string (for example `2026-04-23T23:45:12Z`). Takes no arguments.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
    },
};

/// Execute a built-in tool by name. Returns caller-owned text; errors
/// bubble so the runner can record the failure as the tool result.
fn dispatchBuiltinTool(
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    _ = arguments_json; // only one tool, ignores args.
    if (std.mem.eql(u8, name, "get_current_time")) {
        return renderCurrentTimeIso8601(allocator, clock.nowNs());
    }
    return error.UnknownTool;
}

/// Format nanoseconds-since-epoch as ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`).
/// Uses Howard Hinnant's `civil_from_days` algorithm so no libc tz
/// dependency is needed and the result is stable across platforms.
fn renderCurrentTimeIso8601(allocator: std.mem.Allocator, now_ns: i128) ![]u8 {
    const secs: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));
    const days: i64 = @divFloor(secs, 86_400);
    const secs_of_day: i64 = @mod(secs, 86_400);
    const hh: u8 = @intCast(@divTrunc(secs_of_day, 3600));
    const mm: u8 = @intCast(@divTrunc(@mod(secs_of_day, 3600), 60));
    const ss: u8 = @intCast(@mod(secs_of_day, 60));

    const d0 = days + 719_468;
    const era: i64 = if (d0 >= 0) @divFloor(d0, 146_097) else @divFloor(d0 - 146_096, 146_097);
    const doe: u32 = @intCast(d0 - era * 146_097);
    const yoe: u32 = (doe -% @divFloor(doe, 1460) +% @divFloor(doe, 36_524) -% @divFloor(doe, 146_096)) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, m, d, hh, mm, ss },
    );
}

/// Produce a single-string representation of an assistant turn that
/// contains both text and (optionally) tool_use intents. The context
/// engine stores each ingested message as a flat string; this marker
/// keeps enough detail that future assemble calls can reproduce the
/// turn's intent to the model.
fn renderAssistantTurn(
    allocator: std.mem.Allocator,
    text: []const u8,
    tool_calls: []const types.ToolCall,
) ![]u8 {
    if (tool_calls.len == 0) return allocator.dupe(u8, text);

    var buf: std.array_list.Aligned(u8, null) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, text);
    for (tool_calls) |tc| {
        if (buf.items.len > 0) try buf.append(allocator, '\n');
        const line = try std.fmt.allocPrint(
            allocator,
            "[tool_call {s} {s}({s})]",
            .{ tc.id, tc.name, tc.arguments_json },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    return buf.toOwnedSlice(allocator);
}

/// Parsed agent manifest. `model` is heap-allocated; caller owns.
const AgentManifest = struct {
    provider: ProviderKind,
    model: []u8,
};

/// Parse `agent.json` for the agent's provider + model.
/// Try `<workspace>/.tigerclaw/<sub>/<agent>/<file>` first, fall back
/// to `<home>/.tigerclaw/<sub>/<agent>/<file>`. Returns caller-owned
/// bytes. The supplied `missing_err` is raised iff both paths miss.
fn readCascade(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: []const u8,
    home: []const u8,
    sub: []const u8,
    agent: []const u8,
    file: []const u8,
    limit: std.Io.Limit,
    missing_err: LoadError,
) LoadError![]u8 {
    if (workspace.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.tigerclaw/{s}/{s}/{s}", .{ workspace, sub, agent, file }) catch
            return missing_err;
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit)) |b| return b else |_| {}
    }
    if (home.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.tigerclaw/{s}/{s}/{s}", .{ home, sub, agent, file }) catch
            return missing_err;
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit)) |b| return b else |_| {}
    }
    return missing_err;
}

/// Same cascade as `readCascade` but for root-level files
/// (`<root>/.tigerclaw/<file>`, no agent sub-path).
fn readRootCascade(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: []const u8,
    home: []const u8,
    file: []const u8,
    limit: std.Io.Limit,
    missing_err: LoadError,
) LoadError![]u8 {
    if (workspace.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.tigerclaw/{s}", .{ workspace, file }) catch
            return missing_err;
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit)) |b| return b else |_| {}
    }
    if (home.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.tigerclaw/{s}", .{ home, file }) catch
            return missing_err;
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit)) |b| return b else |_| {}
    }
    return missing_err;
}

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

test "context engine: assemble returns prior turns in session order" {
    // Exercises the same ingest/assemble sequence liveRun uses, so a
    // regression that drops history in the runner will surface here
    // without needing a live provider on the wire.
    const allocator = testing.allocator;
    const engine = try context_root.default_engine.DefaultEngine.init(allocator);
    defer engine.deinit();

    var sys_clock: clock_mod.SystemClock = .{};
    const clock_value = sys_clock.clock();
    const bundle = context_mod.Context{
        .io = undefined,
        .alloc = allocator,
        .clock = &clock_value,
        .trace_id = std.mem.zeroes(context_mod.TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "sess-1",
        .origin_channel_id = null,
    };

    const e = engine.engine();
    _ = try e.vtable.ingest(&bundle, e.ptr, .{
        .session_id = "sess-1",
        .message_id = "m1",
        .role = .user,
        .content = "hello",
    });
    _ = try e.vtable.ingest(&bundle, e.ptr, .{
        .session_id = "sess-1",
        .message_id = "m2",
        .role = .assistant,
        .content = "hi back",
    });

    const result = try e.vtable.assemble(&bundle, e.ptr, .{
        .session_id = "sess-1",
        .prompt = "how are you?",
        .model = "test",
        .available_tools = &.{},
        .token_budget = 4096,
    });
    defer engine.freeAssembleResult(result);

    // Three sections: two history turns + the current prompt.
    try testing.expectEqual(@as(usize, 3), result.sections.len);

    var saw_user_hello = false;
    var saw_asst_hi = false;
    var saw_prompt = false;
    for (result.sections) |s| {
        if (s.kind == .history_turn and s.role == .user and
            std.mem.eql(u8, s.content, "hello")) saw_user_hello = true;
        if (s.kind == .history_turn and s.role == .assistant and
            std.mem.eql(u8, s.content, "hi back")) saw_asst_hi = true;
        if (s.kind == .current_prompt and
            std.mem.eql(u8, s.content, "how are you?")) saw_prompt = true;
    }
    try testing.expect(saw_user_hello);
    try testing.expect(saw_asst_hi);
    try testing.expect(saw_prompt);
}

test "renderCurrentTimeIso8601: fixed timestamp renders canonically" {
    const ns: i128 = 1_609_556_645 * @as(i128, std.time.ns_per_s);
    const out = try renderCurrentTimeIso8601(testing.allocator, ns);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2021-01-02T03:04:05Z", out);
}

test "dispatchBuiltinTool: get_current_time matches renderCurrentTimeIso8601" {
    var fc = clock_mod.FixedClock{ .value_ns = 1_609_556_645 * @as(i128, std.time.ns_per_s) };
    const out = try dispatchBuiltinTool(testing.allocator, fc.clock(), "get_current_time", "{}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2021-01-02T03:04:05Z", out);
}

test "dispatchBuiltinTool: unknown name returns UnknownTool" {
    var fc = clock_mod.FixedClock{ .value_ns = 0 };
    try testing.expectError(
        error.UnknownTool,
        dispatchBuiltinTool(testing.allocator, fc.clock(), "no_such_tool", "{}"),
    );
}

test "renderAssistantTurn: text only passes through unchanged" {
    const out = try renderAssistantTurn(testing.allocator, "hello", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "renderAssistantTurn: adds bracketed markers for tool calls" {
    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "get_current_time", .arguments_json = "{}" },
    };
    const out = try renderAssistantTurn(testing.allocator, "", &calls);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[tool_call call_1 get_current_time({})]", out);
}

test "context engine: sessions are isolated" {
    const allocator = testing.allocator;
    const engine = try context_root.default_engine.DefaultEngine.init(allocator);
    defer engine.deinit();

    var sys_clock: clock_mod.SystemClock = .{};
    const clock_value = sys_clock.clock();
    var bundle = context_mod.Context{
        .io = undefined,
        .alloc = allocator,
        .clock = &clock_value,
        .trace_id = std.mem.zeroes(context_mod.TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "sess-A",
        .origin_channel_id = null,
    };

    const e = engine.engine();
    _ = try e.vtable.ingest(&bundle, e.ptr, .{
        .session_id = "sess-A",
        .message_id = "m1",
        .role = .user,
        .content = "private A",
    });

    bundle.session_id = "sess-B";
    const result = try e.vtable.assemble(&bundle, e.ptr, .{
        .session_id = "sess-B",
        .prompt = "prompt-B",
        .model = "test",
        .available_tools = &.{},
        .token_budget = 4096,
    });
    defer engine.freeAssembleResult(result);

    // sess-B should only see its own prompt, not sess-A's content.
    try testing.expectEqual(@as(usize, 1), result.sections.len);
    try testing.expectEqual(context_root.types.SectionKind.current_prompt, result.sections[0].kind);
}
