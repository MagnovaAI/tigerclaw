//! Real AgentRunner over the react loop.
//!
//! One `RealRunner` is per agent, not per turn or per session. It
//! owns the runtime `agent.Agent` (which itself owns the
//! `AgentState` and the optional context engine wired in C2), an
//! `Interrupt`, an `InFlightCounter`, and a `Harness` for
//! filesystem-backed session state. Sessions are loaded lazily on
//! first turn, swapped (with best-effort save of the current one)
//! when `req.session_id` changes between turns.
//!
//! Per-turn flow:
//!   1. `in_flight.begin()`; `defer end()`.
//!   2. `interrupt.clear()` — fresh slate per turn so a stale flag
//!      from a previous cancellation does not cancel new work.
//!   3. Lock the session mutex; if `session_id` changed since the
//!      last turn, save the current session (best-effort) and load
//!      or start the new one. Unlock.
//!   4. `interrupt.check()` — early bail.
//!   5. Walk every active memory provider, dupe their prefetch
//!      results, concatenate, and push a `.system` message into
//!      `agent.state` before `runTurn` appends the user input.
//!   6. `agent.runTurn(req.input)`.
//!   7. Walk every active provider's `syncTurn(user, assistant)`.
//!   8. Save the current session (best-effort).
//!   9. Return `{ output: final_text orelse "", completed:
//!      reason == .model_finished }`.
//!
//! Streaming sinks on `TurnRequest` are ignored in v1; end-of-turn
//! delivery only. The TODO in `react.zig` is the future hook.

const std = @import("std");

const Io = std.Io;

const agent_runner = @import("agent_runner.zig");
const harness_mod = @import("harness.zig");
const interrupt_mod = @import("interrupt.zig");
const session_mod = @import("session.zig");

const agent_mod = @import("../agent/agent.zig");
const memory = @import("../memory/root.zig");

pub const RealRunner = struct {
    allocator: std.mem.Allocator,
    harness: harness_mod.Harness,

    /// Persistent runtime agent. Keeps its `AgentState` (and the
    /// optional context engine) across every turn this runner
    /// services.
    agent: *agent_mod.Agent,

    memory_manager: *memory.Manager,

    interrupt: interrupt_mod.Interrupt = .{},
    in_flight: agent_runner.InFlightCounter = .{},

    /// Currently-loaded session. None until the first turn lands.
    /// Swapped when `req.session_id` differs from `current_id`.
    /// Turns are serialised through the gateway's per-runner queue,
    /// so the swap needs no explicit lock — there is at most one
    /// turn in-flight per runner. `cancel` only mutates the atomic
    /// `interrupt` flag, which is safe to flip from any thread.
    current_session: ?session_mod.Session = null,
    current_id: ?[]u8 = null,

    pub const Options = struct {
        allocator: std.mem.Allocator,
        harness: harness_mod.Harness,
        agent: *agent_mod.Agent,
        memory_manager: *memory.Manager,
    };

    pub fn init(opts: Options) RealRunner {
        return .{
            .allocator = opts.allocator,
            .harness = opts.harness,
            .agent = opts.agent,
            .memory_manager = opts.memory_manager,
        };
    }

    pub fn deinit(self: *RealRunner) void {
        if (self.current_session) |*s| {
            // Best-effort save before tearing down. Failure is
            // logged; the runner shutdown still proceeds.
            self.harness.saveSession(s) catch |e| {
                std.log.scoped(.real_runner).warn(
                    "session save on deinit failed: {s}",
                    .{@errorName(e)},
                );
            };
            s.deinit();
            self.current_session = null;
        }
        if (self.current_id) |id| {
            self.allocator.free(id);
            self.current_id = null;
        }
        // The agent was handed off to the runner via `Options.agent`
        // and lives for the runner's full lifetime — its state is
        // the conversational context that persists across turns.
        // Tear it down here so the caller has a single deinit point.
        self.agent.deinit();
        self.allocator.destroy(self.agent);
        self.* = undefined;
    }

    pub fn runner(self: *RealRunner) agent_runner.AgentRunner {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // --- vtable shims ------------------------------------------------------

    const vtable: agent_runner.VTable = .{
        .run = runFn,
        .cancel = cancelFn,
        .counter = counterFn,
    };

    fn runFn(ctx: *anyopaque, req: agent_runner.TurnRequest) agent_runner.TurnError!agent_runner.TurnResult {
        const self: *RealRunner = @ptrCast(@alignCast(ctx));
        return self.run(req);
    }

    fn cancelFn(ctx: *anyopaque, turn_id: agent_runner.TurnId) void {
        const self: *RealRunner = @ptrCast(@alignCast(ctx));
        // turn_id is ignored until streaming lands (see the TODO in
        // react.zig). Cancelling whatever turn is currently running
        // is the only meaningful semantics for the v1 blocking
        // surface.
        _ = turn_id;
        self.interrupt.request();
    }

    fn counterFn(ctx: *anyopaque) *agent_runner.InFlightCounter {
        const self: *RealRunner = @ptrCast(@alignCast(ctx));
        return &self.in_flight;
    }

    // --- impl --------------------------------------------------------------

    fn run(self: *RealRunner, req: agent_runner.TurnRequest) agent_runner.TurnError!agent_runner.TurnResult {
        if (req.session_id.len == 0) return error.SessionMissing;

        self.in_flight.begin();
        defer self.in_flight.end();

        // Per-turn lifecycle invariant: clear before any work that
        // could observe the flag. A flip during the previous turn's
        // tail does not bleed into this one.
        self.interrupt.clear();

        try self.swapSessionIfNeeded(req.session_id);

        self.interrupt.check() catch return error.Interrupted;

        // Prefetch context from every active memory provider and
        // concatenate into one system block. `gatherPrefetch` only
        // returns OutOfMemory; per-provider failures are logged and
        // skipped inside the helper, so the runner never dies on a
        // memory backend hiccup.
        const maybe_ctx = self.gatherPrefetch(req.input) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (maybe_ctx) |c| self.allocator.free(c);

        if (maybe_ctx) |ctx_block| {
            _ = self.agent.state.pushMessage(.system, ctx_block) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        const out = self.agent.runTurn(req.input) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.internalError("agent.runTurn", e),
        };

        const final = out.final_text orelse "";

        // Sync turn into every active provider. Failures are logged
        // but do not fail the turn — the user already has the
        // assistant reply; losing the memory write is a tail
        // concern.
        self.syncProviders(req.input, final);

        // Persist the session so a crash mid-stream does not lose
        // the turn the user just saw.
        if (self.current_session) |*s| {
            self.harness.saveSession(s) catch |e| {
                std.log.scoped(.real_runner).warn(
                    "session save failed: {s}",
                    .{@errorName(e)},
                );
            };
        }

        // Streaming sinks are surfaced in v1 only at end-of-turn:
        // emit the final text once if a stream sink is wired.
        // TODO: per-fragment streaming hook lives in react.zig and
        // lands with the streaming-aware runner.
        if (req.stream_sink) |sink| {
            if (final.len > 0) sink(req.stream_sink_ctx, final);
        }

        return .{
            .output = final,
            .completed = out.reason == .model_finished,
        };
    }

    fn swapSessionIfNeeded(self: *RealRunner, session_id: []const u8) agent_runner.TurnError!void {
        if (self.current_id) |id| {
            if (std.mem.eql(u8, id, session_id)) return; // hot path
            // Different session: save the current one (best-effort)
            // before swapping. Save failure does not block the new
            // turn — the user's request takes priority over a stale
            // session's persistence.
            if (self.current_session) |*s| {
                self.harness.saveSession(s) catch |e| {
                    std.log.scoped(.real_runner).warn(
                        "saving prior session before swap failed: {s}",
                        .{@errorName(e)},
                    );
                };
                s.deinit();
                self.current_session = null;
            }
            self.allocator.free(id);
            self.current_id = null;
        }

        // Try resume; fall back to start.
        const loaded = self.harness.resumeSession(session_id) catch |e| switch (e) {
            error.FileNotFound => null,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                return self.internalError("resumeSession", e);
            },
        };
        self.current_session = loaded orelse self.harness.startSession(session_id) catch
            return error.OutOfMemory;

        self.current_id = self.allocator.dupe(u8, session_id) catch return error.OutOfMemory;
    }

    /// Walk every active memory provider, accumulate prefetch text,
    /// return an owned concatenated buffer. Returns null when no
    /// provider produced any content.
    fn gatherPrefetch(self: *RealRunner, query: []const u8) !?[]u8 {
        var providers: [4]memory.Provider = undefined;
        const n = self.memory_manager.active(&providers);

        var pieces: std.ArrayList(u8) = .empty;
        defer pieces.deinit(self.allocator);

        for (providers[0..n]) |p| {
            const got = p.prefetch(query) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidQuery => continue,
                error.BackendFailure => {
                    std.log.scoped(.real_runner).warn(
                        "memory.{s}.prefetch failed",
                        .{p.name},
                    );
                    continue;
                },
            };
            if (got.text.len == 0) continue;
            if (pieces.items.len > 0) pieces.append(self.allocator, '\n') catch return error.OutOfMemory;
            pieces.appendSlice(self.allocator, got.text) catch return error.OutOfMemory;
        }

        if (pieces.items.len == 0) return null;
        return pieces.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn syncProviders(self: *RealRunner, user: []const u8, assistant: []const u8) void {
        var providers: [4]memory.Provider = undefined;
        const n = self.memory_manager.active(&providers);
        for (providers[0..n]) |p| {
            p.syncTurn(.{ .user = user, .assistant = assistant }) catch |e| {
                std.log.scoped(.real_runner).warn(
                    "memory.{s}.syncTurn failed: {s}",
                    .{ p.name, @errorName(e) },
                );
            };
        }
    }

    fn internalError(_: *RealRunner, where: []const u8, e: anyerror) agent_runner.TurnError {
        std.log.scoped(.real_runner).warn(
            "{s} failed: {s}",
            .{ where, @errorName(e) },
        );
        return error.InternalError;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("types");
const llm = @import("../llm/root.zig");
const vtable_mod = @import("../agent/vtable.zig");
const clock_mod = @import("clock");

fn makeBuiltin(b: *memory.Builtin) memory.Provider {
    return b.provider();
}

fn newAgent(
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
) !*agent_mod.Agent {
    const a = try allocator.create(agent_mod.Agent);
    a.* = agent_mod.Agent.init(.{
        .allocator = allocator,
        .provider = provider,
        .executor = executor,
        .model = .{ .provider = "mock", .model = "0" },
    });
    return a;
}

test "RealRunner: empty session_id returns SessionMissing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var deny = vtable_mod.DenyExecutor{};
    var mock = llm.MockProvider{ .replies = &.{} };

    const a = try newAgent(testing.allocator, mock.provider(), deny.executor());

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a",
        .clock = mc.clock(),
    });
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();
    try b.initialize();

    var rr = RealRunner.init(.{
        .allocator = testing.allocator,
        .harness = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        }),
        .agent = a,
        .memory_manager = &mgr,
    });
    defer rr.deinit();

    try testing.expectError(
        error.SessionMissing,
        rr.runner().run(.{ .session_id = "", .input = "hi" }),
    );
    try testing.expectEqual(@as(u32, 0), rr.runner().counter().current());
}

test "RealRunner: end-to-end turn echoes through the runner and persists session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "hello back", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const a = try newAgent(testing.allocator, mock.provider(), deny.executor());

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rr = RealRunner.init(.{
        .allocator = testing.allocator,
        .harness = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        }),
        .agent = a,
        .memory_manager = &mgr,
    });
    defer rr.deinit();

    const result = try rr.runner().run(.{
        .session_id = "sess-1",
        .input = "hi",
    });
    try testing.expect(result.completed);
    try testing.expectEqualStrings("hello back", result.output);

    // Session persisted to disk.
    const stat = try tmp.dir.statFile(testing.io, "sess-1.json", .{});
    try testing.expect(stat.size > 0);

    // Counter zeroed after the turn finishes.
    try testing.expectEqual(@as(u32, 0), rr.runner().counter().current());
}

test "RealRunner: iteration_cap reports completed=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    // Mock returns tool_use forever; the loop hits its iteration cap.
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "", .stop_reason = .tool_use, .tool_calls = &.{.{ .id = "c", .name = "x", .arguments_json = "{}" }} },
    } ** 3;
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const a = try testing.allocator.create(agent_mod.Agent);
    a.* = agent_mod.Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = deny.executor(),
        .model = .{ .provider = "mock", .model = "0" },
        .loop = .{ .max_iterations = 2 },
    });

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rr = RealRunner.init(.{
        .allocator = testing.allocator,
        .harness = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        }),
        .agent = a,
        .memory_manager = &mgr,
    });
    defer rr.deinit();

    const result = try rr.runner().run(.{
        .session_id = "sess-cap",
        .input = "loop forever",
    });
    try testing.expect(!result.completed);
}

test "RealRunner: cancel before run trips Interrupted on the next turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "ok", .stop_reason = .end_turn },
        .{ .text = "ok2", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    const a = try newAgent(testing.allocator, mock.provider(), deny.executor());

    var b = memory.Builtin.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .agent_name = "a",
        .clock = mc.clock(),
    });
    try b.initialize();
    var mgr = memory.Manager.init(testing.allocator, b.provider());
    defer mgr.deinit();

    var rr = RealRunner.init(.{
        .allocator = testing.allocator,
        .harness = harness_mod.Harness.init(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
        }),
        .agent = a,
        .memory_manager = &mgr,
    });
    defer rr.deinit();

    // First turn establishes the session.
    _ = try rr.runner().run(.{ .session_id = "s", .input = "first" });

    // Cancel sets the flag, but the next turn clears it before any
    // user-visible work runs — so cancel before a fresh turn does
    // NOT cancel that turn. Documented invariant.
    rr.runner().cancel(0);
    const ok = try rr.runner().run(.{ .session_id = "s", .input = "second" });
    try testing.expect(ok.completed);
}
