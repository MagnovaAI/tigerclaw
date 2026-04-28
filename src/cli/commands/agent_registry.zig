//! Per-process agent registry — maps `agent_name` → `LiveAgentRunner`.
//!
//! The gateway loads every directory under `~/.tigerclaw/agents/` at
//! boot and stashes one runner per agent. The route handler reads the
//! `agent` field from the request body and routes the turn to the
//! matching runner. Falls back to the registry's `default_runner`
//! (typically the first one loaded) when the request omits an agent.
//!
//! Single-threaded by design — the gateway dispatcher serialises
//! requests through the same handler, so the registry doesn't need
//! per-runner locks. The runners themselves rotate their `last_output`
//! between calls; the registry just owns the dict + the mock fallback.

const std = @import("std");
const harness = @import("../../harness/root.zig");
const live_runner = @import("live_runner.zig");

pub const Entry = struct {
    name: []u8,
    runner: live_runner.LiveAgentRunner,
};

pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Aligned(Entry, null),
    /// Used when no agent is loadable AND we need the gateway to come
    /// up cleanly anyway (tests, fresh installs without an agents
    /// directory). Mirrors the existing MockAgentRunner behaviour.
    mock_fallback: harness.MockAgentRunner,
    /// Single shared in-flight counter the gateway's drain loop polls.
    /// All per-agent runners decrement onto this same counter so the
    /// drain sees the correct sum across agents.
    in_flight: harness.agent_runner.InFlightCounter,
    /// Index into `entries` of the agent used when a request omits the
    /// `agent` field. -1 means "no live agents loaded; use mock".
    default_index: i32 = -1,

    pub fn init(allocator: std.mem.Allocator) AgentRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .mock_fallback = harness.MockAgentRunner.init(),
            .in_flight = harness.agent_runner.InFlightCounter.init(),
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.name);
            e.runner.deinit();
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Load every agent directory, cascading workspace over global.
    /// An agent directory that appears in both places resolves against
    /// the workspace overlay (`<workspace>/.tigerclaw/agents/<name>/`);
    /// agents present only in `<home>/.tigerclaw/agents/` still load.
    /// A directory whose `agent.json` fails to parse is skipped with a
    /// warning rather than aborting the boot.
    pub fn loadAll(
        self: *AgentRegistry,
        io: std.Io,
        workspace: []const u8,
        home: []const u8,
    ) !void {
        if (workspace.len == 0 and home.len == 0) return;

        // Walk both candidate dirs; collect distinct agent names, with
        // workspace appearing first so its name claim wins.
        var seen = std.BufSet.init(self.allocator);
        defer seen.deinit();

        const roots: [2][]const u8 = .{ workspace, home };
        for (roots) |root| {
            if (root.len == 0) continue;

            var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_path_buf, "{s}/.tigerclaw/agents", .{root}) catch continue;
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                if (entry.name.len == 0 or entry.name[0] == '.') continue;
                if (seen.contains(entry.name)) continue; // workspace won earlier

                try seen.insert(entry.name);

                const owned_name = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(owned_name);

                const loaded = live_runner.LiveAgentRunner.load(
                    self.allocator,
                    io,
                    entry.name,
                    workspace,
                    home,
                ) catch |e| {
                    std.debug.print(
                        "agent_registry: skipping '{s}' — {s}\n",
                        .{ entry.name, @errorName(e) },
                    );
                    self.allocator.free(owned_name);
                    continue;
                };

                try self.entries.append(self.allocator, .{ .name = owned_name, .runner = loaded });
                if (self.default_index < 0) self.default_index = @intCast(self.entries.items.len - 1);
            }
        }
    }

    /// Returns the AgentRunner vtable. Internally dispatches through
    /// our adapter so the route handler doesn't need to know about the
    /// registry — it just calls `runner.run(.{...})` and we look up
    /// the right backend by `req.session_id` (which the CLI sets to
    /// the agent name; the route handler can override by parsing the
    /// request body).
    pub fn runner(self: *AgentRegistry) harness.agent_runner.AgentRunner {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: harness.agent_runner.VTable = .{
        .run = registryRun,
        .cancel = registryCancel,
        .counter = registryCounter,
        .set_sandbox = registrySetSandbox,
    };

    fn registrySetSandbox(
        ctx: *anyopaque,
        mode: harness.agent_runner.SandboxMode,
        path: []const u8,
    ) anyerror!void {
        const self: *AgentRegistry = @ptrCast(@alignCast(ctx));
        // Fan out to every loaded agent. The TUI tracks one
        // sandbox state for the whole UI; mirroring that to every
        // agent keeps the policy uniform — sub-turn dispatches see
        // the same gate the user just set on the active agent.
        for (self.entries.items) |*e| {
            const sub = e.runner.runner();
            if (sub.vtable.set_sandbox) |_| try sub.setSandbox(mode, path);
        }
    }

    fn registryCounter(ctx: *anyopaque) *harness.agent_runner.InFlightCounter {
        const self: *AgentRegistry = @ptrCast(@alignCast(ctx));
        return &self.in_flight;
    }

    fn registryCancel(ctx: *anyopaque, turn_id: harness.agent_runner.TurnId) void {
        const self: *AgentRegistry = @ptrCast(@alignCast(ctx));
        // Best-effort: forward to every loaded agent. v0.1.0 has no
        // per-turn tracking; cancel is idempotent and the next run
        // simply doesn't get sent to the provider.
        for (self.entries.items) |*e| {
            e.runner.runner().cancel(turn_id);
        }
    }

    fn registryRun(
        ctx: *anyopaque,
        req: harness.agent_runner.TurnRequest,
    ) harness.agent_runner.TurnError!harness.agent_runner.TurnResult {
        const self: *AgentRegistry = @ptrCast(@alignCast(ctx));
        self.in_flight.begin();
        defer self.in_flight.end();

        // Route by session_id (the CLI sets this to the agent name in
        // v0.1.0; the route handler can also override by reading the
        // body's `agent` field — but the dispatcher fixed-shape API
        // doesn't expose the body here, so session_id is the routing
        // key for v0.1.0).
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, req.session_id)) {
                return e.runner.runner().run(req);
            }
        }

        // No matching agent — fall back to the default if one exists,
        // else the mock so the gateway still answers something.
        if (self.default_index >= 0) {
            const idx: usize = @intCast(self.default_index);
            return self.entries.items[idx].runner.runner().run(req);
        }
        return self.mock_fallback.runner().run(req);
    }
};
