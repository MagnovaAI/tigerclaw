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

    /// Resolved root directory for the agent's workspace. All
    /// file tools (read_file/write_file/list_files/edit_file)
    /// resolve their `path` argument relative to this. Always
    /// `<root>/.tigerclaw/agents/<name>/workspace`; owned.
    agent_workspace_root: []u8,

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

        // SOUL.md is optional at both layers. It defines the agent's
        // persona / voice; the tool catalog is appended to it below
        // so every agent is told what it can actually call. A model
        // that just sees schemas via the Anthropic `tools` channel
        // still often refuses with "I can't do that"; a short prose
        // list in the system prompt reliably flips that behaviour.
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
        defer if (soul) |s| allocator.free(s);

        const system_prompt = try buildSystemPrompt(allocator, soul);

        // Resolve the file-tool sandbox root: prefer the workspace
        // copy (per-project scratch dir) with fallback to the home
        // copy (per-user scratch dir). We don't create it eagerly;
        // write_file creates on demand.
        const agent_workspace_root = try resolveAgentWorkspaceRoot(
            allocator,
            workspace,
            home,
            agent_name,
        );

        const engine = try context_root.default_engine.DefaultEngine.init(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .in_flight = harness.agent_runner.InFlightCounter.init(),
            .provider_kind = manifest.provider,
            .api_key = api_key,
            .model = manifest.model,
            .system_prompt = system_prompt,
            .agent_workspace_root = agent_workspace_root,
            .context_engine = engine,
        };
    }

    /// Build the final system prompt sent to the provider: the
    /// agent's SOUL.md (if any) followed by an auto-generated
    /// catalog of the tools in `builtin_tools`. The catalog is
    /// generated rather than authored so adding a tool to the
    /// table immediately teaches every agent about it — no
    /// per-agent prompt edit needed.
    fn buildSystemPrompt(allocator: std.mem.Allocator, soul: ?[]const u8) LoadError!?[]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        if (soul) |s| {
            try buf.appendSlice(allocator, s);
            if (s.len > 0 and s[s.len - 1] != '\n') try buf.append(allocator, '\n');
            try buf.append(allocator, '\n');
        }

        try buf.appendSlice(allocator,
            \\# Available tools
            \\
            \\You have these tools available. Call them instead of guessing, refusing,
            \\or telling the user to do the work themselves. Each tool's JSON schema
            \\is provided separately; the list below is for quick reference.
            \\
            \\When the user names a tool by the name of the underlying CLI it wraps
            \\(for example "use lightpanda", "run the calculator", "grab the time"),
            \\treat that as a request to invoke the matching tool directly — do not
            \\ask them to clarify or apologise. If the user's intent is unambiguous,
            \\make the tool call on the first try.
            \\
            \\`fetch_url` does not work well against search engines (Google, Bing,
            \\DuckDuckGo etc.) — they serve consent walls or anti-bot pages to
            \\headless browsers. Prefer direct URLs (the restaurant's own site,
            \\Wikipedia, official sources). When the user asks to "search the web",
            \\ask them for a site to try, or suggest one from memory, rather than
            \\fetching a Google results page.
            \\
            \\
        );
        for (builtin_tools) |t| {
            buf.append(allocator, '-') catch return error.OutOfMemory;
            buf.append(allocator, ' ') catch return error.OutOfMemory;
            buf.append(allocator, '`') catch return error.OutOfMemory;
            buf.appendSlice(allocator, t.name) catch return error.OutOfMemory;
            buf.append(allocator, '`') catch return error.OutOfMemory;
            buf.appendSlice(allocator, " — ") catch return error.OutOfMemory;
            buf.appendSlice(allocator, t.description) catch return error.OutOfMemory;
            buf.append(allocator, '\n') catch return error.OutOfMemory;
        }

        if (buf.items.len == 0) return null;
        return try buf.toOwnedSlice(allocator);
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
        self.allocator.free(self.agent_workspace_root);
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

        // The messages list owns every Message — including its
        // content blocks and the inner slices each block points at.
        // `Message.freeOwned` walks the union and frees each variant
        // appropriately. The context-engine sections are flat-string
        // borrows that we copy into owned text blocks below; in-loop
        // appends (assistant text, tool_use, tool_result) likewise
        // own everything they hold.
        var messages: std.ArrayList(types.Message) = .empty;
        defer {
            for (messages.items) |m| m.freeOwned(self.allocator);
            messages.deinit(self.allocator);
        }
        for (assembled.sections) |section| {
            // `current_prompt` duplicates the user message we just
            // ingested; skip it rather than send the same text twice.
            if (section.kind == .current_prompt) continue;
            // Prefer the engine's structured blocks when present —
            // those preserve tool_use / tool_result linkage across
            // turns. Fall back to wrapping flat content in a single
            // text block for legacy text-only sections (system
            // preamble, channel state, plain user/assistant turns
            // ingested without structured blocks).
            const msg = if (section.blocks) |bs|
                try messageFromBlocks(self.allocator, mapRole(section.role), bs)
            else
                try types.Message.allocText(self.allocator, mapRole(section.role), section.content);
            try messages.append(self.allocator, msg);
        }

        // Dispatch loop: the model may answer with tool_use instead of
        // a final reply. Execute each tool locally, ingest the
        // assistant + tool messages into history, and call the
        // provider again. The loop only exits when the model emits
        // a response with no tool calls — there's no per-turn cap.
        // The model self-terminates with a text reply; the user can
        // always Ctrl-C to interrupt a runaway turn.
        var round: u32 = 0;
        var final_text: []u8 = &.{};
        errdefer self.allocator.free(final_text);
        var last_stop: types.StopReason = .end_turn;

        while (true) : (round += 1) {
            const chat_req: llm.provider.ChatRequest = .{
                .messages = messages.items,
                .model = .{ .provider = @tagName(self.provider_kind), .model = self.model },
                .system = self.system_prompt,
                .max_output_tokens = 1024,
                .tools = &builtin_tools,
            };

            // Route every provider call through `chatStream` so the
            // sink (if the caller supplied one on `req`) sees text
            // deltas as soon as they decode. When the caller didn't
            // set a sink we still go through chatStream — the vtable
            // fallback fires once at end-of-turn, same shape as the
            // old `chat` path.
            const resp = blk: {
                if (req.stream_sink) |s| {
                    break :blk owned.provider.chatStream(self.allocator, chat_req, s, req.stream_sink_ctx) catch
                        return error.InternalError;
                }
                break :blk owned.provider.chat(self.allocator, chat_req) catch
                    return error.InternalError;
            };
            defer resp.deinit(self.allocator);
            last_stop = resp.stop_reason;

            const text = resp.text orelse "";

            // Record whatever the assistant said (text and/or the
            // tool-use intent). We persist BOTH a flat-text marker
            // (for legacy text-only consumers) AND the structured
            // ContentBlock slice (for the runner to replay verbatim
            // on the next turn). Persisting structured blocks is
            // what closes the multi-turn loop — without it, history
            // replay loses the tool_use_id link and the model can't
            // correlate its own calls with the next turn's
            // tool_result blocks.
            if (text.len > 0 or resp.tool_calls.len > 0) {
                const marker = try renderAssistantTurn(self.allocator, text, resp.tool_calls);
                defer self.allocator.free(marker);

                // Build a borrowed view of the assistant blocks for
                // the engine to deep-copy. Stack-style — the engine
                // owns the persistent copy after `ingest` returns.
                const has_text = text.len > 0;
                const block_count = (if (has_text) @as(usize, 1) else 0) + resp.tool_calls.len;
                const ingest_blocks = try self.allocator.alloc(types.ContentBlock, block_count);
                defer self.allocator.free(ingest_blocks);
                var ibi: usize = 0;
                if (has_text) {
                    ingest_blocks[ibi] = .{ .text = text };
                    ibi += 1;
                }
                for (resp.tool_calls) |tc| {
                    ingest_blocks[ibi] = .{ .tool_use = .{
                        .id = tc.id,
                        .name = tc.name,
                        .input_json = tc.arguments_json,
                    } };
                    ibi += 1;
                }

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
                        .blocks = ingest_blocks,
                    },
                ) catch return error.InternalError;
            }

            // No tool calls means the model gave its final answer.
            // We always run any pending tool calls and loop back so
            // the transcript stays consistent — even when the model
            // emits a chatty intermediary text alongside the call.
            // Cutting the loop short on text+tool combos breaks
            // history persistence and the model loses track of
            // what it has and hasn't run.
            if (resp.tool_calls.len == 0) {
                self.allocator.free(final_text);
                final_text = try self.allocator.dupe(u8, text);
                break;
            }

            // Build the assistant message with structured content:
            // an optional leading text block (when the model spoke
            // before the tool call), followed by one tool_use block
            // per call. Then dispatch each tool, build a single
            // user message holding all tool_result blocks, and
            // append both messages so the next provider iteration
            // sees the proper transcript shape.
            //
            // Tool ids correlate `tool_use` and `tool_result` blocks
            // — Anthropic 400s if a tool_result references an id
            // that didn't appear in the preceding assistant
            // message's tool_use blocks.
            {
                const has_text = text.len > 0;
                const block_count = (if (has_text) @as(usize, 1) else 0) + resp.tool_calls.len;
                const blocks = try self.allocator.alloc(types.ContentBlock, block_count);
                errdefer self.allocator.free(blocks);

                var bi: usize = 0;
                if (has_text) {
                    blocks[bi] = .{ .text = try self.allocator.dupe(u8, text) };
                    bi += 1;
                }
                for (resp.tool_calls) |tc| {
                    blocks[bi] = .{ .tool_use = .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .input_json = try self.allocator.dupe(u8, tc.arguments_json),
                    } };
                    bi += 1;
                }
                try messages.append(self.allocator, .{
                    .role = .assistant,
                    .content = blocks,
                });
            }

            // Execute each tool and build the matching user message
            // carrying tool_result blocks. We dispatch all tools
            // first, collect the result text for each, then assemble
            // one user message with N tool_result blocks. Anthropic
            // expects the tool_result(s) to ride on a single user
            // turn following the assistant's tool_use turn.
            const result_blocks = try self.allocator.alloc(types.ContentBlock, resp.tool_calls.len);
            errdefer self.allocator.free(result_blocks);

            for (resp.tool_calls, 0..) |tc, idx| {
                // Fire a `.started` event before dispatch so the TUI
                // can render a pending tool line. The runner never
                // sees the sink output; it's a side channel for the
                // gateway's SSE forwarder.
                if (req.tool_event_sink) |s| {
                    s(req.tool_event_sink_ctx, .started, tc.id, tc.name, "");
                }
                var tool_failed = false;
                const result_text = dispatchBuiltinTool(
                    self.allocator,
                    self.io,
                    clock_value,
                    self.agent_workspace_root,
                    tc.name,
                    tc.arguments_json,
                ) catch |e| blk: {
                    tool_failed = true;
                    break :blk std.fmt.allocPrint(
                        self.allocator,
                        "tool {s} failed: {s}",
                        .{ tc.name, @errorName(e) },
                    ) catch return error.OutOfMemory;
                };
                if (req.tool_event_sink) |s| {
                    s(req.tool_event_sink_ctx, .finished, tc.id, tc.name, result_text);
                }

                // Persist the result with both a flat-text view AND
                // a structured tool_result block. The structured
                // block carries the tool_use_id so future turns can
                // correlate it back to the assistant's tool_use
                // call from this round.
                const tool_msg_id = try self.nextMessageId();
                defer self.allocator.free(tool_msg_id);
                const ingest_tr_blocks = [_]types.ContentBlock{.{ .tool_result = .{
                    .tool_use_id = tc.id,
                    .content = result_text,
                    .is_error = tool_failed,
                } }};
                _ = self.context_engine.engine().vtable.ingest(
                    &context_bundle,
                    self.context_engine.engine().ptr,
                    .{
                        .session_id = req.session_id,
                        .message_id = tool_msg_id,
                        .role = .tool,
                        .content = result_text,
                        .blocks = &ingest_tr_blocks,
                    },
                ) catch return error.InternalError;

                // The block takes ownership of result_text and the
                // duped tool_use_id. Don't free result_text here —
                // it's now owned by the block, which will be freed
                // by `Message.freeOwned` when the messages list
                // tears down.
                result_blocks[idx] = .{ .tool_result = .{
                    .tool_use_id = try self.allocator.dupe(u8, tc.id),
                    .content = result_text,
                    .is_error = tool_failed,
                } };
            }

            try messages.append(self.allocator, .{
                .role = .user,
                .content = result_blocks,
            });
        }

        // The loop exited via the no-tool-calls break, but the
        // final response had no text. Surface a hint so the user
        // isn't staring at nothing — likely the provider returned
        // an empty turn (refusal, content filter, or transcript
        // problem). The round count helps debugging.
        if (final_text.len == 0) {
            final_text = try std.fmt.allocPrint(
                self.allocator,
                "(no reply after {d} tool round(s) — try rephrasing)",
                .{round},
            );
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

    /// Map context-engine Role to the LLM wire Role. The engine
    /// has a `.tool` category for past tool results; on replay we
    /// collapse it to `.user` because the wire shape no longer has
    /// a tool role — tool results live as `tool_result` content
    /// blocks on user messages.
    fn mapRole(r: context_root.types.Role) types.Role {
        return switch (r) {
            .system => .system,
            .user, .tool => .user,
            .assistant => .assistant,
        };
    }
};

/// Build a heap-owned `types.Message` from a slice of borrowed
/// `ContentBlock`s. Each inner allocation is duplicated into
/// `allocator` so the returned message can be freed with
/// `Message.freeOwned` independently of the source slice's
/// lifetime — important because the blocks come straight off the
/// engine's stored messages, which have their own ownership.
fn messageFromBlocks(
    allocator: std.mem.Allocator,
    role: types.Role,
    blocks: []const types.ContentBlock,
) !types.Message {
    const out = try allocator.alloc(types.ContentBlock, blocks.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |b| switch (b) {
            .text => |s| allocator.free(s),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input_json);
            },
            .tool_result => |tr| {
                allocator.free(tr.tool_use_id);
                allocator.free(tr.content);
            },
        };
        allocator.free(out);
    }
    for (blocks) |b| {
        out[written] = switch (b) {
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            .tool_use => |tu| .{ .tool_use = .{
                .id = try allocator.dupe(u8, tu.id),
                .name = try allocator.dupe(u8, tu.name),
                .input_json = try allocator.dupe(u8, tu.input_json),
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try allocator.dupe(u8, tr.tool_use_id),
                .content = try allocator.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
        };
        written += 1;
    }
    return .{ .role = role, .content = out };
}

/// The tool schemas the runner exposes to every agent. A real
/// plug-based registry is future work; this table is intentionally
/// small so the model gets short, memorable tool names.
const builtin_tools = [_]types.Tool{
    .{
        .name = "get_current_time",
        .description = "Return the current date and time as an ISO-8601 UTC string (for example `2026-04-23T23:45:12Z`). Takes no arguments.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
    },
    .{
        .name = "calculate",
        .description = "Evaluate a numeric expression. Supports `+ - * / %` and parentheses on decimal numbers. Returns the result as a decimal string.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\",\"description\":\"The arithmetic expression to evaluate, e.g. (2 + 3) * 4.\"}},\"required\":[\"expression\"]}",
    },
    .{
        .name = "random_number",
        .description = "Return a pseudorandom integer in the inclusive range [min, max]. Uses the session clock as seed so outputs are deterministic across a given turn.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"min\":{\"type\":\"integer\"},\"max\":{\"type\":\"integer\"}},\"required\":[\"min\",\"max\"]}",
    },
    .{
        .name = "fetch_url",
        .description = "Fetch a web page via the Lightpanda headless browser and return it as readable markdown (headings, links, lists) rather than raw HTML. JavaScript runs before the page is dumped, so SPA content is included. Call this tool whenever the user says 'fetch', 'browse', 'scrape', 'look up <a topic> online', 'visit', 'check this page', 'open this URL', or names Lightpanda directly. Only http:// and https:// URLs are allowed; private and loopback addresses are refused. Response is capped at 8 KB and truncated with a visible marker; if you need more, re-issue with a more specific URL.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"Absolute URL to fetch.\"}},\"required\":[\"url\"]}",
    },
    .{
        .name = "read_file",
        .description = "Read a UTF-8 text file from the agent's workspace. `path` is relative to the workspace root; absolute paths and `..` traversal are refused. Returns up to 64 KiB.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    },
    .{
        .name = "write_file",
        .description = "Write UTF-8 text to a file in the agent's workspace. Creates parent directories on demand. Overwrites existing content. Max 64 KiB. Path rules: relative only, no `..`.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
    },
    .{
        .name = "list_files",
        .description = "List the entries of a directory in the agent's workspace. `path` is relative; empty string or `.` lists the workspace root. Returns one entry per line prefixed with `f` (file) or `d` (dir).",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
    },
    .{
        .name = "edit_file",
        .description = "Replace the first occurrence of `old_text` with `new_text` inside a file under the agent's workspace. Fails if `old_text` is not found or appears more than once. Use for small in-place edits.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_text\":{\"type\":\"string\"},\"new_text\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_text\",\"new_text\"]}",
    },
};

/// Execute a built-in tool by name. Returns caller-owned text; errors
/// bubble so the runner can record the failure as the tool result.
fn dispatchBuiltinTool(
    allocator: std.mem.Allocator,
    io: std.Io,
    clock: clock_mod.Clock,
    workspace_root: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, name, "get_current_time")) {
        return renderCurrentTimeIso8601(allocator, clock.nowNs());
    }
    if (std.mem.eql(u8, name, "calculate")) {
        return runCalculate(allocator, arguments_json);
    }
    if (std.mem.eql(u8, name, "random_number")) {
        return runRandomNumber(allocator, clock.nowNs(), arguments_json);
    }
    if (std.mem.eql(u8, name, "fetch_url")) {
        return runFetchUrl(allocator, io, arguments_json);
    }
    if (std.mem.eql(u8, name, "read_file")) {
        return runReadFile(allocator, io, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, name, "write_file")) {
        return runWriteFile(allocator, io, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, name, "list_files")) {
        return runListFiles(allocator, io, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, name, "edit_file")) {
        return runEditFile(allocator, io, workspace_root, arguments_json);
    }
    return error.UnknownTool;
}

// ---------------------------------------------------------------------------
// calculate

/// Evaluate the arithmetic expression under `"expression"`. The
/// grammar is the classic precedence-climbing one:
///   expr    = term  { ('+' | '-') term }
///   term    = factor { ('*' | '/' | '%') factor }
///   factor  = ['-'] primary
///   primary = number | '(' expr ')'
fn runCalculate(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    const Args = struct { expression: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var p = ExprParser{ .src = parsed.value.expression, .pos = 0 };
    const value = try p.parseExpr();
    p.skipSpaces();
    if (p.pos != p.src.len) return error.TrailingInput;

    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

const ExprParser = struct {
    src: []const u8,
    pos: usize,

    fn skipSpaces(self: *ExprParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn parseExpr(self: *ExprParser) anyerror!f64 {
        var lhs = try self.parseTerm();
        while (true) {
            self.skipSpaces();
            if (self.pos >= self.src.len) break;
            const op = self.src[self.pos];
            if (op != '+' and op != '-') break;
            self.pos += 1;
            const rhs = try self.parseTerm();
            lhs = if (op == '+') lhs + rhs else lhs - rhs;
        }
        return lhs;
    }

    fn parseTerm(self: *ExprParser) anyerror!f64 {
        var lhs = try self.parseFactor();
        while (true) {
            self.skipSpaces();
            if (self.pos >= self.src.len) break;
            const op = self.src[self.pos];
            if (op != '*' and op != '/' and op != '%') break;
            self.pos += 1;
            const rhs = try self.parseFactor();
            lhs = switch (op) {
                '*' => lhs * rhs,
                '/' => if (rhs == 0) return error.DivisionByZero else lhs / rhs,
                '%' => if (rhs == 0) return error.DivisionByZero else @mod(lhs, rhs),
                else => unreachable,
            };
        }
        return lhs;
    }

    fn parseFactor(self: *ExprParser) anyerror!f64 {
        self.skipSpaces();
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
            return -try self.parseFactor();
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ExprParser) anyerror!f64 {
        self.skipSpaces();
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        if (self.src[self.pos] == '(') {
            self.pos += 1;
            const v = try self.parseExpr();
            self.skipSpaces();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.UnmatchedParen;
            self.pos += 1;
            return v;
        }
        // Number
        const start = self.pos;
        while (self.pos < self.src.len and
            (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.'))
        {
            self.pos += 1;
        }
        if (self.pos == start) return error.ExpectedNumber;
        return std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return error.InvalidNumber;
    }
};

// ---------------------------------------------------------------------------
// random_number

/// Deterministic PRNG: mix the session clock with the min/max bounds
/// via `std.Random.DefaultPrng`. Each turn's output is stable given
/// the same clock reading, and the model can't tell the difference
/// from a hardware RNG.
fn runRandomNumber(allocator: std.mem.Allocator, now_ns: i128, arguments_json: []const u8) ![]u8 {
    const Args = struct { min: i64, max: i64 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const min = parsed.value.min;
    const max = parsed.value.max;
    if (max < min) return error.EmptyRange;

    const seed: u64 = @intCast(@mod(now_ns, std.math.maxInt(i64)));
    var prng = std.Random.DefaultPrng.init(seed);
    const span: u64 = @intCast(max - min + 1);
    const pick: u64 = prng.random().uintLessThan(u64, span);
    const value: i64 = min + @as(i64, @intCast(pick));
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

// ---------------------------------------------------------------------------
// fetch_url

/// Fetch a URL via the locally-installed Lightpanda headless browser
/// and return the rendered page as markdown. Uses the compiled
/// `lightpanda` binary on $PATH (written in Zig but distributed as a
/// pre-built executable) — linking Lightpanda as a Zig module is not
/// yet viable on Zig 0.16 because its build graph still targets 0.15.
///
/// SSRF guard: the URL's hostname is rejected if it parses to any
/// loopback / RFC 1918 / link-local literal before we spawn the
/// subprocess. Hostname-based DNS rebinding is out of scope here
/// (future-work concern shared with the older direct-HTTP version).
fn runFetchUrl(allocator: std.mem.Allocator, io: std.Io, arguments_json: []const u8) ![]u8 {
    _ = io;
    const Args = struct { url: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const url = parsed.value.url;

    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.DisallowedScheme;
    }

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const host: []const u8 = switch (uri.host orelse return error.MissingHost) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    try ensurePublicHost(host);

    return runLightpanda(allocator, url);
}

/// Hard cap on rendered-page bytes returned to the model. Pages
/// larger than this are truncated with a trailing `[truncated …]`
/// marker. Sized to fit comfortably in a single LLM tool-result
/// turn — a Haiku-class model handling 8 KiB of markdown is fast;
/// 64 KiB stalls the agent loop and bloats history beyond what
/// the TUI can re-render at 60 FPS.
const fetch_max_bytes: usize = 8 * 1024;

/// Bytes we read from lightpanda before deciding to truncate. A few
/// KiB of headroom over the hard cap so the truncation marker can
/// honestly say "more was available".
const fetch_read_window: usize = fetch_max_bytes + 4 * 1024;

/// Spawn `lightpanda fetch --dump markdown <url>` via libc popen (the
/// same pattern `findOrphanPid` uses in `gateway.zig`, for the same
/// reason: Zig 0.16's `std.process.Child` spawn-and-read pipeline is
/// still in transition). Reads up to `fetch_read_window` bytes of
/// stdout, then truncates the result to `fetch_max_bytes` with a
/// visible marker so a runaway page can't exhaust the heap or
/// stall the LLM.
fn runLightpanda(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Build the shell command. URL must be sanitised — refuse any
    // single-quote in the URL so the shell can't be talked out of its
    // quoting (the SSRF check above already rejected most attack
    // surface; this is a belt on top of it).
    if (std.mem.indexOfScalar(u8, url, '\'') != null) return error.InvalidUrl;

    // 8 KiB is enough for the full command line; a URL longer than
    // that is almost certainly malformed.
    var cmd_buf: [8 * 1024]u8 = undefined;
    // `--wait_until domcontentloaded` returns as soon as the HTML +
    // synchronous scripts settle, instead of the default `load` which
    // waits for every image/xhr/tracker. Pages with perpetual network
    // activity (Google, infinite scroll, ad-rotating SPAs) used to
    // hang the subprocess indefinitely under `load`. `--wait_ms 2000`
    // is lightpanda's own hard cap — it returns what it has rendered
    // after 2 seconds no matter what. We rely on that rather than
    // wrapping the subprocess in a shell-level watchdog.
    const cmd = std.fmt.bufPrintZ(
        &cmd_buf,
        "lightpanda fetch --dump markdown --wait_until domcontentloaded --wait_ms 2000 '{s}' 2>/dev/null",
        .{url},
    ) catch return error.InvalidUrl;

    const f = popen(cmd.ptr, "r") orelse return error.FetchFailed;
    defer _ = pclose(f);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 4096);

    var chunk: [4096]u8 = undefined;
    var saw_more = false;
    while (true) {
        const n = fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        const room = fetch_read_window - out.items.len;
        const take = @min(n, room);
        try out.appendSlice(allocator, chunk[0..take]);
        if (take < n or out.items.len >= fetch_read_window) {
            saw_more = true;
            break;
        }
    }

    if (out.items.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "lightpanda fetch timed out or returned no output for {s}",
            .{url},
        );
    }

    // Apply the visible cap. If the page was longer than the cap,
    // shrink the buffer and append a marker so the model knows it's
    // looking at a prefix.
    const truncated = saw_more or out.items.len > fetch_max_bytes;
    if (out.items.len > fetch_max_bytes) {
        out.shrinkRetainingCapacity(fetch_max_bytes);
    }
    if (truncated) {
        try out.appendSlice(allocator, "\n\n[truncated to ");
        var num_buf: [32]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{fetch_max_bytes}) catch "8192";
        try out.appendSlice(allocator, num);
        try out.appendSlice(allocator, " bytes — re-issue fetch_url with a more specific URL if you need more]");
    }

    return out.toOwnedSlice(allocator);
}

// libc shims for popen-based subprocess I/O. Mirrors the bindings in
// `gateway.zig` but kept local so `live_runner` has no dependency on
// the gateway module.
const LP_FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*LP_FILE;
extern "c" fn pclose(stream: *LP_FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, stream: *LP_FILE) usize;

/// Refuse hostnames that parse as loopback/private/link-local IPs.
/// DNS-based bypasses (e.g. `evil.example.com` pointing at
/// 192.168.x.x) are not caught here — the minimal version checks
/// only the literal IP form, which is the common SSRF vector.
fn ensurePublicHost(host: []const u8) !void {
    // Strip brackets if IPv6 literal: `[::1]` -> `::1`.
    const raw = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;

    // Try IPv4 literal first, then IPv6. A DNS name (e.g. `example.com`)
    // fails both and falls through — DNS-resolved SSRF isn't caught
    // here; it's a future-work concern.
    if (std.Io.net.IpAddress.parseIp4(raw, 0)) |ip| {
        const b = ip.ip4.bytes;
        // 127.0.0.0/8 loopback
        if (b[0] == 127) return error.DisallowedAddress;
        // 10.0.0.0/8
        if (b[0] == 10) return error.DisallowedAddress;
        // 172.16.0.0/12
        if (b[0] == 172 and (b[1] & 0xF0) == 0x10) return error.DisallowedAddress;
        // 192.168.0.0/16
        if (b[0] == 192 and b[1] == 168) return error.DisallowedAddress;
        // 169.254.0.0/16 link-local (incl. AWS metadata 169.254.169.254)
        if (b[0] == 169 and b[1] == 254) return error.DisallowedAddress;
        // 0.0.0.0/8 "this network"
        if (b[0] == 0) return error.DisallowedAddress;
        return;
    } else |_| {}

    if (std.Io.net.IpAddress.parseIp6(raw, 0)) |ip| {
        const b = ip.ip6.bytes;
        // ::1 loopback
        var is_loopback = true;
        for (b[0..15]) |byte| if (byte != 0) {
            is_loopback = false;
            break;
        };
        if (is_loopback and b[15] == 1) return error.DisallowedAddress;
        // fc00::/7 unique local
        if ((b[0] & 0xFE) == 0xFC) return error.DisallowedAddress;
        // fe80::/10 link-local
        if (b[0] == 0xFE and (b[1] & 0xC0) == 0x80) return error.DisallowedAddress;
        return;
    } else |_| {}

    // Not an IP literal — a hostname. Accept.
}

// ---------------------------------------------------------------------------
// file tools (read_file / write_file / list_files / edit_file)
//
// Every file tool resolves its `path` argument inside the agent's
// workspace root. The sandbox boundary is enforced by
// `ensureSafeRelPath` — it rejects paths the agent could use to
// escape the workspace (absolute paths, `..` components, NUL
// bytes). We intentionally do *not* resolve symlinks; the workspace
// root is created by tigerclaw itself on first write, so the agent
// can't pre-plant one that points elsewhere.

/// Enforce the file-tool path policy: path must be non-empty, not
/// absolute, must not contain any `..` component, and must not
/// contain NUL. Empty string and `.` are normalised to `.` so
/// callers can use them to refer to the workspace root itself.
fn ensureSafeRelPath(path: []const u8) ![]const u8 {
    if (path.len == 0) return ".";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.fs.path.isAbsolute(path)) return error.PathEscapesWorkspace;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (std.mem.eql(u8, comp, "..")) return error.PathEscapesWorkspace;
    }
    return path;
}

/// Open (and lazily create) the workspace root directory, then
/// open `rel` inside it. Caller closes the returned Dir.
fn openWorkspaceDir(io: std.Io, workspace_root: []const u8) !std.Io.Dir {
    // Root itself may not yet exist — create it. Then open.
    std.Io.Dir.cwd().createDirPath(io, workspace_root) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.Io.Dir.cwd().openDir(io, workspace_root, .{});
}

fn runReadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct { path: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const rel = try ensureSafeRelPath(parsed.value.path);

    var root = try openWorkspaceDir(io, workspace_root);
    defer root.close(io);

    return root.readFileAlloc(io, rel, allocator, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => error.FileNotFound,
        else => error.ReadFailed,
    };
}

fn runWriteFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct { path: []const u8, content: []const u8 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const rel = try ensureSafeRelPath(parsed.value.path);
    if (std.mem.eql(u8, rel, ".")) return error.InvalidPath;
    if (parsed.value.content.len > 64 * 1024) return error.TooLarge;

    var root = try openWorkspaceDir(io, workspace_root);
    defer root.close(io);

    // Ensure parent dirs exist so `foo/bar/baz.txt` works when
    // nothing below the root has been created yet.
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) {
            root.createDirPath(io, parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return error.WriteFailed,
            };
        }
    }

    root.writeFile(io, .{ .sub_path = rel, .data = parsed.value.content }) catch return error.WriteFailed;

    return std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ parsed.value.content.len, rel });
}

fn runListFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    // path is optional — missing or empty means the workspace root.
    const Args = struct { path: []const u8 = "" };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const rel = try ensureSafeRelPath(parsed.value.path);

    var root = try openWorkspaceDir(io, workspace_root);
    defer root.close(io);

    var target = if (std.mem.eql(u8, rel, "."))
        try std.Io.Dir.cwd().openDir(io, workspace_root, .{ .iterate = true })
    else
        try root.openDir(io, rel, .{ .iterate = true });
    defer target.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = target.iterate();
    while (try it.next(io)) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .file, .sym_link => 'f',
            else => '?',
        };
        try out.append(allocator, kind);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\n');
    }

    if (out.items.len == 0) return allocator.dupe(u8, "(empty)");
    return out.toOwnedSlice(allocator);
}

fn runEditFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const rel = try ensureSafeRelPath(parsed.value.path);
    if (std.mem.eql(u8, rel, ".")) return error.InvalidPath;
    if (parsed.value.old_text.len == 0) return error.EmptyOldText;

    var root = try openWorkspaceDir(io, workspace_root);
    defer root.close(io);

    const current = root.readFileAlloc(io, rel, allocator, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ReadFailed,
    };
    defer allocator.free(current);

    // Enforce uniqueness so the model can't accidentally overwrite
    // multiple sites with a single `old_text`. If more than one
    // match exists, the user probably wanted a more specific anchor.
    const first = std.mem.indexOf(u8, current, parsed.value.old_text) orelse return error.OldTextNotFound;
    const second = std.mem.indexOfPos(u8, current, first + 1, parsed.value.old_text);
    if (second != null) return error.OldTextNotUnique;

    const prefix = current[0..first];
    const suffix = current[first + parsed.value.old_text.len ..];
    const new_total = prefix.len + parsed.value.new_text.len + suffix.len;
    if (new_total > 64 * 1024) return error.TooLarge;

    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(allocator);
    try next.ensureTotalCapacity(allocator, new_total);
    next.appendSliceAssumeCapacity(prefix);
    next.appendSliceAssumeCapacity(parsed.value.new_text);
    next.appendSliceAssumeCapacity(suffix);

    root.writeFile(io, .{ .sub_path = rel, .data = next.items }) catch return error.WriteFailed;

    return std.fmt.allocPrint(allocator, "edited {s}: 1 replacement ({d} bytes)", .{ rel, new_total });
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

/// Resolve the sandbox directory for file tools. Prefers the
/// workspace-scoped copy (`<workspace>/.tigerclaw/agents/<name>/workspace`)
/// so agents scratched in-project don't spill into the user's
/// home dir; falls back to the home copy. Caller owns the slice.
fn resolveAgentWorkspaceRoot(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    home: []const u8,
    agent_name: []const u8,
) LoadError![]u8 {
    const root = if (workspace.len > 0) workspace else home;
    if (root.len == 0) return error.HomeMissing;
    return std.fmt.allocPrint(allocator, "{s}/.tigerclaw/agents/{s}/workspace", .{ root, agent_name }) catch
        error.OutOfMemory;
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
    const out = try dispatchBuiltinTool(testing.allocator, undefined, fc.clock(), "", "get_current_time", "{}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2021-01-02T03:04:05Z", out);
}

test "dispatchBuiltinTool: unknown name returns UnknownTool" {
    var fc = clock_mod.FixedClock{ .value_ns = 0 };
    try testing.expectError(
        error.UnknownTool,
        dispatchBuiltinTool(testing.allocator, undefined, fc.clock(), "", "no_such_tool", "{}"),
    );
}

test "calculate: basic arithmetic with precedence and parens" {
    const out = try runCalculate(testing.allocator, "{\"expression\":\"(2 + 3) * 4\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("20", out);
}

test "calculate: unary minus" {
    const out = try runCalculate(testing.allocator, "{\"expression\":\"-7 + 10\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("3", out);
}

test "calculate: division by zero returns DivisionByZero" {
    try testing.expectError(
        error.DivisionByZero,
        runCalculate(testing.allocator, "{\"expression\":\"1 / 0\"}"),
    );
}

test "calculate: trailing garbage rejected" {
    try testing.expectError(
        error.TrailingInput,
        runCalculate(testing.allocator, "{\"expression\":\"1 + 1 oops\"}"),
    );
}

test "random_number: deterministic for a fixed seed + range" {
    const a = try runRandomNumber(testing.allocator, 42, "{\"min\":0,\"max\":100}");
    defer testing.allocator.free(a);
    const b = try runRandomNumber(testing.allocator, 42, "{\"min\":0,\"max\":100}");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "random_number: empty range rejected" {
    try testing.expectError(
        error.EmptyRange,
        runRandomNumber(testing.allocator, 0, "{\"min\":5,\"max\":3}"),
    );
}

test "fetch_url: non-http scheme rejected" {
    try testing.expectError(
        error.DisallowedScheme,
        runFetchUrl(testing.allocator, undefined, "{\"url\":\"file:///etc/passwd\"}"),
    );
}

test "fetch_url: loopback IPv4 rejected" {
    try testing.expectError(
        error.DisallowedAddress,
        runFetchUrl(testing.allocator, undefined, "{\"url\":\"http://127.0.0.1:8765/health\"}"),
    );
}

test "fetch_url: RFC 1918 private address rejected" {
    try testing.expectError(
        error.DisallowedAddress,
        runFetchUrl(testing.allocator, undefined, "{\"url\":\"http://192.168.1.1/admin\"}"),
    );
}

test "fetch_url: link-local metadata endpoint rejected" {
    try testing.expectError(
        error.DisallowedAddress,
        runFetchUrl(testing.allocator, undefined, "{\"url\":\"http://169.254.169.254/latest/meta-data/\"}"),
    );
}

test "fetch_url: IPv6 loopback rejected" {
    try testing.expectError(
        error.DisallowedAddress,
        runFetchUrl(testing.allocator, undefined, "{\"url\":\"http://[::1]/x\"}"),
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
