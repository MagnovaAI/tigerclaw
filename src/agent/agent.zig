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

pub const Options = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
    loop: loop_mod.Config = .{},
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    provider: llm.Provider,
    executor: vtable_mod.ToolExecutor,
    model: types.ModelRef,
    loop_cfg: loop_mod.Config,
    state: state_mod.AgentState,

    pub fn init(opts: Options) Agent {
        return .{
            .allocator = opts.allocator,
            .provider = opts.provider,
            .executor = opts.executor,
            .model = opts.model,
            .loop_cfg = opts.loop,
            .state = state_mod.AgentState.init(opts.allocator),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.state.deinit();
        self.* = undefined;
    }

    /// Push `user_input` onto the transcript and drive the react
    /// loop until termination.
    pub fn runTurn(self: *Agent, user_input: []const u8) !loop_mod.RunOutcome {
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
