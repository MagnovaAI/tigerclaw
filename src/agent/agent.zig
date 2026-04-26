//! Agent facade.
//!
//! One `Agent` owns a provider, a tool executor, a state, and a
//! loop config. Callers hand it a user message with `runTurn`;
//! it drives the react loop and returns the final outcome. The
//! agent itself is a thin wrapper — everything it does is
//! delegated to the loop — but it gives the runtime one object to
//! hold on to for a session.

const std = @import("std");
const types = @import("types");
const llm = @import("../llm/root.zig");
const state_mod = @import("state.zig");
const vtable_mod = @import("vtable.zig");
const loop_mod = @import("loop.zig");
const context_engine = @import("context/engine.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
    loop: loop_mod.Config = .{},
    /// Optional context engine. When set, the agent calls
    /// `shouldCompress` at the start of every turn and runs
    /// `prepareForSend` if true, swapping the compacted history
    /// into the state before the user message is pushed. Null =
    /// no compaction (current behaviour, preserved for callers
    /// that haven't migrated).
    context_engine: ?*context_engine.Engine = null,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
    loop_cfg: loop_mod.Config,
    state: state_mod.AgentState,
    context_engine: ?*context_engine.Engine,

    pub fn init(opts: Options) Agent {
        return .{
            .allocator = opts.allocator,
            .provider = opts.provider,
            .executor = opts.executor,
            .model = opts.model,
            .loop_cfg = opts.loop,
            .state = state_mod.AgentState.init(opts.allocator),
            .context_engine = opts.context_engine,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.state.deinit();
        self.* = undefined;
    }

    /// Push `user_input` onto the transcript and drive the react
    /// loop until termination. When a context engine is wired,
    /// `shouldCompress` is queried first; if true, the existing
    /// history is compacted and replaces the state's messages
    /// before the user input is appended. Compaction is per-turn,
    /// not per react-step, so slices returned by `react.step`
    /// remain stable for the duration of a single turn.
    pub fn runTurn(self: *Agent, user_input: []const u8) !loop_mod.RunOutcome {
        if (self.context_engine) |engine| {
            if (engine.shouldCompress(self.state.history())) {
                var prepared = try engine.prepareForSend(self.state.history());
                // Adopt the prepared message slice into the state.
                // `Prepared.hint` and the outer struct's other fields
                // are owned by the engine's allocator (== ours);
                // free them while keeping `messages` for the state.
                self.allocator.free(prepared.hint);
                prepared.hint = &.{};
                try self.state.replaceMessages(prepared.messages);
            }
        }
        _ = try self.state.pushUser(user_input);
        return loop_mod.run(
            &self.state,
            self.provider,
            self.executor,
            self.model,
            self.loop_cfg,
        );
    }

    pub fn history(self: *const Agent) []const types.Message {
        return self.state.history();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Agent: runTurn with context engine compacts when pressure is reached" {
    // Tight window so even a small pre-existing history hits pressure.
    var engine = context_engine.Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 30, .reserve_output_tokens = 0 },
        .policy = .{ .keep_head = 1, .keep_tail = 1 },
    });

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "ok", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    var agent = Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = deny.executor(),
        .model = .{ .provider = "mock", .model = "0" },
        .context_engine = &engine,
    });
    defer agent.deinit();

    // Pre-load state with enough history to trip pressure: 4 × 40
    // bytes ≈ 40 tokens, well past the 30-token cap.
    _ = try agent.state.pushUser("a" ** 40);
    _ = try agent.state.pushAssistant("b" ** 40);
    _ = try agent.state.pushUser("c" ** 40);
    _ = try agent.state.pushAssistant("d" ** 40);
    const before = agent.state.len();

    const out = try agent.runTurn("trigger");
    try testing.expectEqualStrings("ok", out.final_text.?);

    // Compaction must have shortened history before runTurn pushed
    // the new user message and got the assistant reply. After the
    // turn we have: kept (head + tail) + new user + assistant <=
    // before + 2.
    try testing.expect(agent.state.len() < before + 2);
}

test "Agent: runTurn with context engine but no pressure leaves history alone" {
    var engine = context_engine.Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 100_000, .reserve_output_tokens = 1_000 },
    });

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "hi", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    var agent = Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = deny.executor(),
        .model = .{ .provider = "mock", .model = "0" },
        .context_engine = &engine,
    });
    defer agent.deinit();

    _ = try agent.runTurn("hello");
    try testing.expectEqual(@as(usize, 2), agent.state.len());
}

test "Agent: runTurn drives the loop and appends to the transcript" {
    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "hi there", .stop_reason = .end_turn },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var deny = vtable_mod.DenyExecutor{};

    var agent = Agent.init(.{
        .allocator = testing.allocator,
        .provider = mock.provider(),
        .executor = deny.executor(),
        .model = .{ .provider = "mock", .model = "0" },
    });
    defer agent.deinit();

    const out = try agent.runTurn("hello");
    try testing.expectEqualStrings("hi there", out.final_text.?);

    const h = agent.history();
    try testing.expectEqual(@as(usize, 2), h.len);
    try testing.expectEqual(types.Role.user, h[0].role);
    try testing.expectEqualStrings("hello", h[0].flatText());
    try testing.expectEqual(types.Role.assistant, h[1].role);
}
