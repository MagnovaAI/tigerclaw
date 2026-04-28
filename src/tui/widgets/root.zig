//! Root vxfw widget for the TUI.
//!
//! Owns every piece of TUI state and handles every event. The
//! outer `tui.run()` hands this widget to `vxfw.App.run`, which
//! drives the frame loop, event dispatch, and render cycle.
//!
//! This is the fulcrum of the App.run migration: the hand-rolled
//! event loop in the old tui.run() → gone, replaced by
//! `App.run(root.widget())`. Widget methods drive everything.
//!
//! Intermediate state: today the widget renders only a
//! `HeaderWidget`. The history, input box, agent picker, and
//! streaming sink routing are stubs that will land in follow-up
//! commits. Quit on `q` or Ctrl-C is wired so the app is testable
//! end-to-end right now.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("../root.zig");
const tool_preview = @import("../tool_preview.zig");
const md = @import("../md.zig");
const harness = @import("../../harness/root.zig");
const llm_model_context = @import("../../llm/model_context.zig");
const gateway_probe = @import("../../gateway/probe.zig");
const build_options = @import("build_options");
// `Header` (widgets/header.zig) was the old pinned wordmark
// widget. The banner now scrolls with chat as `.banner` rows
// emitted at startup, so the file is no longer imported. Keeping
// it on disk as a reference until we're sure we don't want a
// resurrected pinned-banner mode.
const History = @import("history.zig");
const Input = @import("input.zig");
const Thinking = @import("thinking.zig");
const Hint = @import("hint.zig");
const StatusBar = @import("status_bar.zig");
const mention = @import("../mention.zig");

/// Side-channel logger for the cross-agent dispatch state machine.
/// Writes to `/tmp/tigerclaw-tui.log` so the lines don't bleed into
/// the alt-screen TUI render. Disabled by default — flip on with
/// `--debug` on the CLI or `TIGERCLAW_DEBUG=1` in the environment.
/// Both `info`/`warn` short-circuit when `enabled == false`, so the
/// per-call cost is one atomic load on the hot path.
pub const dispatch_log = struct {
    const file_path = "/tmp/tigerclaw-tui.log";
    /// Cheap spinlock — log calls are infrequent and we only need to
    /// serialize writes so the seconds-tagged lines don't interleave.
    var lock_flag: std.atomic.Value(bool) = .init(false);
    /// Master gate. `setEnabled(true)` is called once at TUI startup
    /// when `--debug` or `TIGERCLAW_DEBUG=1` is set. Lives for the
    /// process lifetime — the flag is process-global because the
    /// logger has no other handle on caller state.
    var enabled_flag: std.atomic.Value(bool) = .init(false);

    pub fn setEnabled(on: bool) void {
        enabled_flag.store(on, .release);
    }

    pub fn isEnabled() bool {
        return enabled_flag.load(.acquire);
    }

    fn write(comptime fmt: []const u8, args: anytype) void {
        if (!enabled_flag.load(.acquire)) return;
        while (lock_flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {}
        defer lock_flag.store(false, .release);
        const mode: std.c.mode_t = 0o644;
        const fd = std.c.open(file_path, std.c.O{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, mode);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var buf: [2048]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        // Wall-clock ts (seconds resolution is enough for tracing).
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const epoch_secs: u64 = @intCast(ts.sec);
        const day_secs = epoch_secs % 86400;
        bw.print("{d:0>2}:{d:0>2}:{d:0>2} ", .{
            (day_secs / 3600) % 24,
            (day_secs / 60) % 60,
            day_secs % 60,
        }) catch return;
        bw.print(fmt, args) catch return;
        bw.writeAll("\n") catch return;
        const out = bw.buffered();
        _ = std.c.write(fd, out.ptr, out.len);
    }

    fn info(comptime fmt: []const u8, args: anytype) void {
        write(fmt, args);
    }

    fn warn(comptime fmt: []const u8, args: anytype) void {
        write("WARN " ++ fmt, args);
    }
};
const CommandMenu = @import("command_menu.zig");
const skills_mod = @import("../../skills/skills.zig");

const Root = @This();

// --- state ---
allocator: std.mem.Allocator,
/// Heap-allocated chat history. Owned by the Root widget; freed
/// on deinit. Lines are appended by the event handler in
/// response to key presses and runner events. The History
/// widget borrows a slice of this list per frame.
history: std.ArrayList(tui.Line) = .empty,
/// Wrap-layout cache for the History widget. Memoises per-line
/// row breakdowns so a re-layout doesn't walk the entire
/// transcript through `gwidth` on every frame. Initialised in
/// `init`, freed in `deinit`.
history_cache: History.WrapCache,
input: Input,
thinking: Thinking = .{},
/// Hint strip above the input. Texts are short borrowed slices
/// — owned by the widget when literal, owned by the Root when
/// dynamic.
hint: Hint = .{ .left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit", .right = "" },
/// Status bar below the input. Values reset to sensible defaults;
/// the agent name lives in the model line so the workspace and
/// sandbox columns stay focused on environment context.
status_bar: StatusBar = .{},
/// Wall-clock instant the current turn started, in ms since
/// the Unix epoch. 0 when no turn is in flight.
turn_started_ms: i64 = 0,
/// Monotonic counter — bumped at each `beginTurn`. Stamped on
/// every tool line so the renderer can group siblings into a
/// single `├─` / `└─` tree per turn.
current_turn_id: u32 = 0,
/// Generation number bumped on every user submit. Worker threads
/// stamp it on every event payload they post; the main loop drops
/// any payload whose epoch differs from the current value. Without
/// this, late events from a cancelled or superseded turn (slow
/// provider reply, sub-turn timeout race) would mutate transcript
/// state belonging to a fresh turn.
turn_epoch: u64 = 0,
/// Cross-agent auto-dispatch state. When an agent's reply mentions
/// other known agents, each mention spawns a sub-turn; once they
/// all complete the invoker is resumed with a join body. This
/// block tracks the in-flight tree per user-turn. All slots reset
/// at `beginTurn`; sub-turn dispatch is wired in step 5b.
subturn_slots: std.ArrayList(SubturnSlot) = .empty,
/// The agent whose reply triggered the current fan-out and is now
/// waiting on `pending_subturns` to drain. Null when no fan-out is
/// in flight. Owned heap slice (duped from `agent_names`).
invoker_to_resume: ?[]u8 = null,
/// Number of sub-turns still in flight for the current fan-out.
/// Decremented on each sub-turn `ue_done`; resume fires when this
/// hits zero.
pending_subturns: usize = 0,
/// Auto-dispatch model-call budget. Counts every sub-turn dispatch
/// plus every invoker resume against `auto_dispatch_max_calls`.
/// Resets on `beginTurn`. The primary user-triggered turn does NOT
/// consume budget — only auto-dispatched calls do.
auto_dispatch_calls: u8 = 0,
auto_dispatch_max_calls: u8 = 8,
/// Per-sub-turn wall-clock cap, in seconds. `0` (the default)
/// disables the watchdog entirely — peers run as long as they
/// need to. The 120s default we used to ship killed legitimate
/// long tool runs (large `write_file`, slow `bash`, file uploads)
/// and surfaced as `! @<peer> timed out` even when the peer was
/// making real progress. Users can opt back in via config when a
/// genuine ceiling is desired.
auto_dispatch_subturn_timeout_secs: u32 = 0,
/// Test-only inspection slot. When `app` is null (tests have not
/// attached a real Vaxis loop), `dispatchResume` stashes the join
/// body here instead of spawning a worker so the test harness can
/// assert on its contents. Production runs always have `app` set
/// before any sub-turn dispatch fires; this field stays null.
last_resume_body: ?[]u8 = null,
/// Accumulator for peer replies the active agent hasn't seen yet.
/// Each sub-turn that completes appends a `[<agent> said: ...]`
/// block here. On the next user submit, the contents are prepended
/// to the runner's message body so the active agent sees what its
/// peers said as part of the user's prompt — no extra model call,
/// no per-agent persistence layer needed. Cleared as soon as it
/// ships. Owned heap slice; null when empty.
peer_chatter: ?[]u8 = null,
/// Borrowed runner. Set by \`attachRunner\` before \`App.run\`;
/// null during tests that don't spin up a real runner.
runner: ?*harness.AgentRunner = null,
/// Agent session id — normally the agent name. Reused across
/// turns so the context engine keeps continuity.
session_id: []const u8 = "tiger",
/// Speaker name for the user's pill (`[ Omkar ]`). Default
/// matches the InitOptions default; overridden at construction.
user_name: []const u8 = "Omkar",
/// All loaded agents (borrowed from the driver's AgentList).
/// `@<name>` mentions are validated against this set; unknown
/// targets fall through to the system-error path.
agent_names: []const []const u8 = &.{},
/// Borrowed App pointer. Used by worker-thread sinks to post
/// UserEvents back into the main loop via \`app.loop.?.postEvent\`.
app: ?*vxfw.App = null,
/// History index of the agent line currently being streamed into,
/// **per agent**. Parallel sub-turns under multi-agent dispatch
/// produce concurrent streams; a single pointer would alternate
/// between speakers and fragment each agent's reply across
/// multiple lines whenever a peer chunk landed in between. Keys
/// are canonical agent slices borrowed from `agent_names`, so
/// they stay alive as long as Root does. Cleared per-agent on
/// tool boundaries and on done; cleared wholesale on user submit
/// and turn cancel.
pending_agent_lines: std.StringHashMapUnmanaged(usize) = .empty,
/// Whether any text has been streamed into the pending agent
/// line yet. If the turn finishes with zero text (tool-only
/// reply, error mid-stream), we drop the empty placeholder.
pending_saw_text: bool = false,
/// Rows of scrollback offset. 0 = the newest line sits at the
/// bottom of the history pane (default behavior). PageUp/Ctrl-U
/// nudge the value up; PageDown/Ctrl-D and any new chunk reset
/// to 0 so streaming output is never hidden.
scroll_offset: u32 = 0,
/// Slash command popup. Visible whenever the input buffer starts
/// with `/`. Cursor selects which command Enter will execute.
command_menu: CommandMenu = .{},
command_menu_cursor: usize = 0,
/// User-toggled: when false, tool_start / tool_done UEs do not
/// add lines to the history. Default on now that tool rows render
/// as a single collapsed `● Tool(args)\n└ summary` block — the
/// status bullet teaches the user something at a glance and Ctrl-B
/// reveals the full body on demand. `/tools off` hides them
/// entirely for users who want zero clutter.
tool_output_enabled: bool = true,
/// Set to true when a slash command requests app shutdown (e.g.
/// `/quit`). The submit handler can't call `ctx.quit = true`
/// directly because the Input widget owns the EventContext at
/// callback time; we flip this flag and the eventHandler honours
/// it on the next pass.
quit_requested: bool = false,
/// Borrowed home dir, used by `/skills` to scan the skills root
/// on demand (so newly-installed skills appear without restart).
home_dir: []const u8 = "",
/// Owned absolute path to the paste-stash directory under
/// `<home>/.tigerclaw/pastes/`. Populated lazily on first attach
/// since `init` doesn't have an allocator-friendly way to build it.
/// Freed in `deinit`.
paste_dir_owned: ?[]u8 = null,
/// Borrowed workspace dir (process cwd at launch). `/lock` with
/// no args defaults to this.
workspace_dir: []const u8 = "",
/// Borrowed std.Io for filesystem reads from slash commands.
io: ?std.Io = null,
/// Sandbox mode mirror. The runner is the source of truth; we
/// keep a local copy so the UI can paint without poking the
/// runner from the draw thread.
sandbox_mode: SandboxMode = .unlocked,
/// Active path when sandbox_mode == .locked. Owned by the
/// allocator; freed on update + on deinit.
sandbox_path: []u8 = &.{},
/// `ask_user` gate mirror — see runner's flag of the same name.
ask_user_gate: bool = true,
/// Set when the agent has called `ask_user` and we're waiting
/// for the user's reply. The next submit will be captured into
/// `pending_reply` instead of starting a new turn. Atomic
/// because the worker thread reads it (via the gate-flip
/// reset path) while the UI thread sets/clears it.
ask_user_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
/// One-shot slot for the user's reply to `ask_user`. Owned;
/// freed by the worker thread after it consumes it.
pending_reply: ?[]u8 = null,
/// Spinlock guarding `pending_reply` since the worker thread
/// reads it concurrently with the UI thread's writes.
pending_reply_busy: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
/// Bridge into the runner. Wired by `attachSandbox` from the
/// TUI runtime; null in tests where the runner doesn't exist.
sandbox_setter: ?*const fn (ctx: *anyopaque, mode: u8, path: []const u8) void = null,
ask_gate_setter: ?*const fn (ctx: *anyopaque, value: bool) void = null,
sandbox_ctx: ?*anyopaque = null,

pub const SandboxMode = enum(u8) { unlocked = 0, locked = 1, plan = 2 };

pub const InitOptions = struct {
    agent_name: []const u8 = "tiger",
    model_line: []const u8 = "",
    workspace: []const u8 = "",
    home: []const u8 = "",
    /// Display name shown on the user's `[ name ]` pill before each
    /// message. Resolved by `tui.run` from
    /// `~/.tigerclaw/config.json:user_name`, then `$USER`, then this
    /// hardcoded fallback. Borrowed; the caller owns the storage.
    user_name: []const u8 = "Omkar",
    /// All loaded agents. Used to validate `@<name>` mentions and
    /// switch the active agent on submit. Borrowed from the TUI
    /// driver's `AgentList`; lifetime exceeds the widget's.
    agent_names: []const []const u8 = &.{},
    io: ?std.Io = null,
    /// Override the cross-agent auto-dispatch model-call cap. Null
    /// keeps the built-in default (8). `tui.run` resolves this from
    /// `~/.tigerclaw/config.json:auto_dispatch_max_calls` if present.
    auto_dispatch_max_calls: ?u8 = null,
};

/// Wrapper around the shared `llm.model_context.maxContext` lookup
/// so the status bar and the runner agree on the per-model window.
fn modelMaxContext(model_line: []const u8) u64 {
    return llm_model_context.maxContext(model_line);
}

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) Root {
    return .{
        .allocator = allocator,
        .input = Input.init(allocator),
        .history_cache = History.WrapCache.init(allocator),
        .session_id = opts.agent_name,
        .user_name = opts.user_name,
        .agent_names = opts.agent_names,
        .home_dir = opts.home,
        .workspace_dir = opts.workspace,
        .io = opts.io,
        .auto_dispatch_max_calls = opts.auto_dispatch_max_calls orelse 8,
        .status_bar = .{
            .agent_name = opts.agent_name,
            .model = opts.model_line,
            .ctx_used = 0,
            .ctx_max = modelMaxContext(opts.model_line),
            .gateway_on = false,
            .sandbox_locked = false,
            .sandbox_path = "",
        },
    };
}

/// Wire the runner + app so submit actually fires a turn. Call
/// after \`init\` and before \`app.run(root.widget(), .{})\`.
pub fn attachRunner(self: *Root, runner: *harness.AgentRunner, app: *vxfw.App) void {
    self.runner = runner;
    self.app = app;

    // Build `<home>/.tigerclaw/pastes` once and hand the borrowed
    // slice to the input widget. Pastes only stash when this is
    // set, so a missing home_dir silently falls back to inline
    // pastes (no crash, just no on-disk stash).
    if (self.paste_dir_owned == null and self.home_dir.len > 0) {
        const path = std.fmt.allocPrint(
            self.allocator,
            "{s}/.tigerclaw/pastes",
            .{self.home_dir},
        ) catch null;
        if (path) |p| {
            self.paste_dir_owned = p;
            self.input.paste_dir = p;
            self.input.paste_io = self.io;
        }
    }
}

/// Tell the status bar whether the gateway daemon is reachable.
/// The TUI sends turns through the daemon, so this must reflect the
/// live probe instead of assuming the gateway is on.
pub fn setGatewayOn(self: *Root, on: bool) void {
    self.status_bar.gateway_on = on;
}

/// Wire the runner-side bridges for sandbox + ask gate.
pub fn attachSandbox(
    self: *Root,
    ctx: *anyopaque,
    sandbox_setter: *const fn (ctx: *anyopaque, mode: u8, path: []const u8) void,
    ask_gate_setter: *const fn (ctx: *anyopaque, value: bool) void,
) void {
    self.sandbox_ctx = ctx;
    self.sandbox_setter = sandbox_setter;
    self.ask_gate_setter = ask_gate_setter;
}

pub fn deinit(self: *Root) void {
    if (self.sandbox_path.len > 0) self.allocator.free(self.sandbox_path);
    for (self.history.items) |*l| {
        l.text.deinit(self.allocator);
        l.deinitSpans(self.allocator);
        l.deinitToolId(self.allocator);
        l.deinitToolFields(self.allocator);
        l.deinitSpeaker(self.allocator);
    }
    self.history.deinit(self.allocator);
    self.history_cache.deinit();
    self.clearSubturnState();
    self.subturn_slots.deinit(self.allocator);
    self.clearAllPendingAgentLines();
    self.pending_agent_lines.deinit(self.allocator);
    if (self.last_resume_body) |b| self.allocator.free(b);
    if (self.peer_chatter) |b| self.allocator.free(b);
    if (self.paste_dir_owned) |p| self.allocator.free(p);
    self.input.deinit();
}

/// Drop every slot's allocations and clear `invoker_to_resume`.
/// Called at `deinit` and on every fresh user submit so a previous
/// fan-out tree never leaks state into a new turn.
fn clearSubturnState(self: *Root) void {
    for (self.subturn_slots.items) |*slot| slot.deinit(self.allocator);
    self.subturn_slots.clearRetainingCapacity();
    if (self.invoker_to_resume) |s| self.allocator.free(s);
    self.invoker_to_resume = null;
    self.pending_subturns = 0;
    self.auto_dispatch_calls = 0;
}

/// Install the Input's submit callback. Called from runVxfw
/// after the Root is fully constructed — the callback captures
/// `&root` via opaque ctx so it can mutate history on Enter.
pub fn wireSubmit(self: *Root) void {
    self.input.on_submit = onSubmit;
    self.input.submit_ctx = self;
}

fn onSubmit(ctx: ?*anyopaque, text: []const u8) void {
    const self: *Root = @ptrCast(@alignCast(ctx.?));
    if (text.len == 0) return;

    // ask_user wait: when an agent question is pending, the next
    // user submit is the reply. We park it in `pending_reply`
    // (worker thread polls), echo the answer in history, and
    // clear the pending flag.
    if (self.ask_user_pending.load(.seq_cst)) {
        const reply_copy = self.allocator.dupe(u8, text) catch return;
        self.beginPendingReply();
        if (self.pending_reply) |old| self.allocator.free(old);
        self.pending_reply = reply_copy;
        self.endPendingReply();
        self.appendUserLine(text) catch {};
        self.ask_user_pending.store(false, .seq_cst);
        self.hint.left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit";
        return;
    }

    // Slash commands are intercepted before they reach the runner.
    // The leading `/` plus the typed name becomes a built-in
    // action; nothing is sent to the LLM.
    if (text.len > 0 and text[0] == '/') {
        // If the menu is open, prefer the highlighted item over
        // the literal typed name — that way users can fuzzy-type
        // a few letters and Enter the menu's pick.
        const literal = text[1..];
        const cmd = blk: {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const visible = CommandMenu.filter(arena.allocator(), literal) catch break :blk literal;
            if (visible.len == 0) break :blk literal;
            const idx = if (self.command_menu_cursor < visible.len) self.command_menu_cursor else 0;
            // The menu entry name might just be a prefix (e.g.
            // user types `/age` and the menu highlights `agents`).
            // Append any literal trailing args (after the first
            // space in `literal`) so `/agents foo` still routes
            // arguments through.
            const space = std.mem.indexOfScalar(u8, literal, ' ');
            if (space) |s| {
                const args_with_space = literal[s..];
                const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ visible[idx].name, args_with_space }) catch break :blk literal;
                self.dispatchCommand(joined);
                self.allocator.free(joined);
                return;
            } else {
                break :blk visible[idx].name;
            }
        };
        self.dispatchCommand(cmd);
        return;
    }

    // Mention routing. If the message starts with `@<name>`, switch
    // the active agent to that name and submit only the stripped
    // body. Subsequent unprefixed messages stay with the new agent
    // — same model as Slack/Discord channel focus.
    const parsed = mention.parse(text);
    if (parsed.target) |target| {
        if (!self.knowsAgent(target)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "! unknown agent: @{s}", .{target}) catch "! unknown agent";
            self.appendLine(.system, msg) catch {};
            return;
        }
        // Switch the active agent. We point session_id and the
        // header/status-bar at the matched agent name *out of the
        // borrowed `agent_names` slice* so the slice's lifetime
        // (the driver's AgentList) keeps it alive — no allocation,
        // no ownership transfer.
        self.setActiveAgent(target);
        // Empty body (`@sage` alone) is a focus-switch only — we
        // echo the user line so the chat shows the redirect, but
        // we don't fire a turn until the user types something.
        if (parsed.body.len == 0) {
            self.appendUserLine(text) catch {};
            return;
        }
    }

    // From here on, `body_to_send` is what actually goes to the
    // runner; the user's pill still shows the original `text`
    // (with `@name` prefix) so the chat reads naturally.
    const body_to_send = parsed.body;

    // Don't start a second turn while one is in flight. The user
    // can type the next message — it'll just queue up as another
    // history line but the runner won't fire.
    if (self.thinking.pending) {
        self.appendUserLine(text) catch {};
        return;
    }
    self.beginTurnWithEcho(text, body_to_send) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "! could not start turn: {s}", .{@errorName(err)}) catch "! turn failed";
        self.appendLine(.system, msg) catch {};
    };
}

/// Run a slash command. `cmd` is the bare name (no leading `/`),
/// optionally followed by a single space and arguments.
fn dispatchCommand(self: *Root, cmd: []const u8) void {
    const space = std.mem.indexOfScalar(u8, cmd, ' ');
    const name = if (space) |s| cmd[0..s] else cmd;
    const args = if (space) |s| std.mem.trim(u8, cmd[s + 1 ..], " \t") else "";

    if (std.mem.eql(u8, name, "quit") or std.mem.eql(u8, name, "exit")) {
        self.quit_requested = true;
        return;
    }
    if (std.mem.eql(u8, name, "tools")) {
        if (args.len == 0 or std.mem.eql(u8, args, "on")) {
            self.tool_output_enabled = true;
            self.appendLine(.system, "tool output: on") catch {};
        } else if (std.mem.eql(u8, args, "off")) {
            self.tool_output_enabled = false;
            self.appendLine(.system, "tool output: off") catch {};
        } else {
            self.appendLine(.system, "usage: /tools [on|off]") catch {};
        }
        return;
    }
    if (std.mem.eql(u8, name, "config")) {
        self.runConfigCommand() catch {};
        return;
    }
    if (std.mem.eql(u8, name, "stop")) {
        // /stop           -> cancel the active agent's current turn
        //                    (same as Esc)
        // /stop <agent>   -> cancel that named agent's in-flight turn,
        //                    even if it's a fan-out peer rather than
        //                    the active foreground agent
        const runner = self.runner orelse {
            self.appendLine(.system, "stop: no runner attached") catch {};
            return;
        };
        if (args.len == 0) {
            if (self.turn_started_ms == 0) {
                self.appendLine(.system, "stop: no turn in flight") catch {};
                return;
            }
            if (!self.thinking.stopping) {
                self.thinking.stopping = true;
                self.status_bar.turn_stopping = true;
                self.hint.left = "stopping turn  ·  waiting for gateway cancel";
                self.appendLine(.system, "∙ stopping turn…") catch {};
                runner.cancel(0);
            }
            return;
        }
        if (!self.knowsAgent(args)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "stop: unknown agent `{s}`", .{args}) catch "stop: unknown agent";
            self.appendLine(.system, msg) catch {};
            return;
        }
        const accepted = runner.cancelByName(args);
        if (!accepted) {
            self.appendLine(.system, "stop: targeted cancel not supported by this runner") catch {};
            return;
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "∙ stopping {s}…", .{args}) catch "∙ stopping…";
        self.appendLine(.system, msg) catch {};
        return;
    }
    if (std.mem.eql(u8, name, "skills") or std.mem.eql(u8, name, "skill")) {
        // `/skills` lists every skill; `/skills <name>` or
        // `/skill <name>` zooms in on a single one with its full
        // description and an `@name` hint.
        self.runSkillsCommandImpl(args) catch {};
        return;
    }
    if (std.mem.eql(u8, name, "lock")) {
        // /lock           -> lock to the launch cwd
        // /lock <path>    -> lock to a user-specified path
        const path_arg = if (args.len > 0) args else self.workspace_dir;
        if (path_arg.len == 0) {
            self.appendLine(.system, "lock: no path available; try `/lock <path>`") catch {};
            return;
        }
        const path_z = self.allocator.dupeZ(u8, path_arg) catch return;
        defer self.allocator.free(path_z);
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_ptr = std.c.realpath(path_z.ptr, &resolved_buf);
        if (resolved_ptr == null) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "lock: cannot resolve `{s}`", .{path_arg}) catch "lock: cannot resolve path";
            self.appendLine(.system, msg) catch {};
            return;
        }
        const resolved_len = std.mem.indexOfScalar(u8, &resolved_buf, 0) orelse resolved_buf.len;
        const resolved = resolved_buf[0..resolved_len];
        if (resolved.len == 0) {
            self.appendLine(.system, "lock: resolved path is empty; aborting") catch {};
            return;
        }
        self.setSandboxMode(.locked, resolved);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "workspace: locked to ") catch {};
        buf.appendSlice(self.allocator, resolved) catch {};
        self.appendLine(.system, buf.items) catch {};
        return;
    }
    if (std.mem.eql(u8, name, "unlock")) {
        self.setSandboxMode(.unlocked, "");
        self.appendLine(.system, "workspace: unlocked") catch {};
        return;
    }
    if (std.mem.eql(u8, name, "plan")) {
        self.setSandboxMode(.plan, "");
        self.appendLine(.system, "workspace: plan mode (read-only; no write_file / edit_file / bash)") catch {};
        return;
    }
    if (std.mem.eql(u8, name, "ask")) {
        if (std.mem.eql(u8, args, "on")) {
            self.setAskGate(true);
            self.appendLine(.system, "ask_user gate: on (the agent can pause to ask questions)") catch {};
        } else if (std.mem.eql(u8, args, "off")) {
            self.setAskGate(false);
            self.appendLine(.system, "ask_user gate: off (the agent will decide on its own)") catch {};
        } else {
            const msg = if (self.ask_user_gate) "ask_user gate: on (use `/ask off` to disable)" else "ask_user gate: off (use `/ask on` to enable)";
            self.appendLine(.system, msg) catch {};
        }
        return;
    }
    if (std.mem.eql(u8, name, "agents")) {
        // Re-using the picker requires hooking back into legacy TUI
        // state that lives outside this widget; surface a hint.
        self.appendLine(.system, "agents picker: press Ctrl-E (slash trigger TBD)") catch {};
        return;
    }

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: /{s}", .{name}) catch "unknown command";
    self.appendLine(.system, msg) catch {};
}

/// Set the active sandbox mode and (optionally) lock path. Mirrors
/// the change into the runner via the bridge so tool dispatch on
/// the worker thread sees the new value on its next call.
fn setSandboxMode(self: *Root, mode: SandboxMode, path: []const u8) void {
    self.sandbox_mode = mode;
    if (self.sandbox_path.len > 0) self.allocator.free(self.sandbox_path);
    self.sandbox_path = if (mode == .locked and path.len > 0)
        self.allocator.dupe(u8, path) catch &.{}
    else
        &.{};

    self.status_bar.sandbox_locked = mode != .unlocked;
    self.status_bar.sandbox_path = self.sandbox_path;

    if (self.sandbox_setter) |setter| {
        if (self.sandbox_ctx) |ctx| setter(ctx, @intFromEnum(mode), self.sandbox_path);
    }
}

fn beginPendingReply(self: *Root) void {
    while (self.pending_reply_busy.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn endPendingReply(self: *Root) void {
    self.pending_reply_busy.store(0, .release);
}

/// Worker-thread entry: post a question into the UI. Hands off
/// ownership of `question` (caller-owned slice copy) to the UE
/// payload; the UI handler frees it after rendering.
pub fn askUserPost(self: *Root, allocator: std.mem.Allocator, question: []const u8) anyerror!void {
    const app = self.app orelse return error.NoApp;
    const payload = try allocator.create(AskUserPayload);
    errdefer allocator.destroy(payload);
    // Read `turn_epoch` directly from `Root` — this entry point is
    // not threaded through `WorkerCtx`. Racing with a fresh user
    // submit is fine: a stale epoch just means `dropStaleIfNeeded`
    // discards the question on the receiving side.
    payload.* = .{
        .epoch = self.turn_epoch,
        .question = try allocator.dupe(u8, question),
    };
    const loop = app.loop orelse return error.NoLoop;
    loop.postEvent(.{ .app = .{ .name = ue_ask_user, .data = payload } });
}

/// Worker-thread entry: signal that the agent gave up waiting
/// (typically because the ask_user gate flipped off). The UI
/// handler clears `ask_user_pending` and resets the hint.
pub fn askUserCancel(self: *Root) void {
    const app = self.app orelse return;
    const loop = app.loop orelse return;
    loop.postEvent(.{ .app = .{ .name = ue_ask_user_cancel, .data = null } });
}

/// Worker-thread entry: try to consume a pending reply. Returns
/// caller-owned slice when one exists, else null.
pub fn askUserTake(self: *Root, allocator: std.mem.Allocator) anyerror!?[]u8 {
    self.beginPendingReply();
    defer self.endPendingReply();
    const slot = self.pending_reply orelse return null;
    self.pending_reply = null;
    defer self.allocator.free(slot);
    return try allocator.dupe(u8, slot);
}

fn setAskGate(self: *Root, value: bool) void {
    self.ask_user_gate = value;
    if (self.ask_gate_setter) |setter| {
        if (self.sandbox_ctx) |ctx| setter(ctx, value);
    }
}

fn runConfigCommand(self: *Root) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, "config:\n");
    try buf.appendSlice(self.allocator, "  agent: ");
    try buf.appendSlice(self.allocator, self.session_id);
    try buf.append(self.allocator, '\n');
    try buf.appendSlice(self.allocator, "  tool_output: ");
    try buf.appendSlice(self.allocator, if (self.tool_output_enabled) "on" else "off");
    try buf.append(self.allocator, '\n');
    try buf.appendSlice(self.allocator, "  sandbox: ");
    try buf.appendSlice(self.allocator, switch (self.sandbox_mode) {
        .unlocked => "unlocked",
        .locked => "locked",
        .plan => "plan",
    });
    if (self.sandbox_mode == .locked and self.sandbox_path.len > 0) {
        try buf.appendSlice(self.allocator, " @ ");
        try buf.appendSlice(self.allocator, self.sandbox_path);
    }
    try buf.append(self.allocator, '\n');
    try buf.appendSlice(self.allocator, "  ask_user: ");
    try buf.appendSlice(self.allocator, if (self.ask_user_gate) "on" else "off");
    try buf.append(self.allocator, '\n');
    try buf.appendSlice(self.allocator, "  home: ");
    try buf.appendSlice(self.allocator, if (self.home_dir.len == 0) "(unset)" else self.home_dir);
    try self.appendLine(.system, buf.items);
}

fn runSkillsCommand(self: *Root) !void {
    return self.runSkillsCommandImpl("");
}

/// `/skills` lists every installed skill; `/skill <name>` (or
/// `/skills <name>`) shows just that one. Each skill renders as
/// its own appendLine row so the user can scroll past long names
/// without one giant wrapped block. The `@<name>` hint nudges the
/// user toward the reference syntax — the agent reads the skill's
/// body when it sees `@<name>` in a user message.
fn runSkillsCommandImpl(self: *Root, target: []const u8) !void {
    if (self.home_dir.len == 0) {
        try self.appendLine(.system, "skills: HOME unset; cannot scan");
        return;
    }
    const io = self.io orelse {
        try self.appendLine(.system, "skills: io unavailable");
        return;
    };
    var list = skills_mod.load(self.allocator, io, self.home_dir) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "skills: failed to load ({s})", .{@errorName(err)}) catch "skills: failed to load";
        try self.appendLine(.system, msg);
        return;
    };
    defer list.deinit();

    if (list.items.len == 0) {
        try self.appendLine(.system, "skills: none installed at ~/.tigerclaw/skills/");
        return;
    }

    if (target.len > 0) {
        for (list.items) |s| {
            if (std.mem.eql(u8, s.name, target)) {
                try self.renderSkillDetail(s);
                return;
            }
        }
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "skill not found: {s}", .{target}) catch "skill not found";
        try self.appendLine(.system, msg);
        return;
    }

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "skills ({d}) — reference one with @<name>",
        .{list.items.len},
    ) catch "skills";
    try self.appendLine(.system, header);

    for (list.items) |s| {
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);
        try line_buf.appendSlice(self.allocator, "  @");
        try line_buf.appendSlice(self.allocator, s.name);
        if (s.description.len > 0) {
            try line_buf.appendSlice(self.allocator, "  —  ");
            // Cap the description at 100 chars per row so a long
            // first-line description doesn't push everything else
            // off the screen on a narrow terminal. The full text
            // is still available via `/skill <name>`.
            const max_desc: usize = 100;
            if (s.description.len <= max_desc) {
                try line_buf.appendSlice(self.allocator, s.description);
            } else {
                try line_buf.appendSlice(self.allocator, s.description[0..max_desc]);
                try line_buf.appendSlice(self.allocator, "…");
            }
        }
        try self.appendLine(.system, line_buf.items);
    }
}

/// Render a single skill's full detail. Used by `/skill <name>`
/// and the picker's Enter dispatch (future work). Header line
/// shows the bare name; description follows on its own row;
/// hint at the bottom reminds the user how to invoke.
fn renderSkillDetail(self: *Root, s: skills_mod.Skill) !void {
    var name_buf: [128]u8 = undefined;
    const name_line = std.fmt.bufPrint(&name_buf, "skill: @{s}", .{s.name}) catch "skill";
    try self.appendLine(.system, name_line);

    if (s.description.len > 0) {
        var desc_buf: std.ArrayList(u8) = .empty;
        defer desc_buf.deinit(self.allocator);
        try desc_buf.appendSlice(self.allocator, "  ");
        try desc_buf.appendSlice(self.allocator, s.description);
        try self.appendLine(.system, desc_buf.items);
    }

    var hint_buf: [256]u8 = undefined;
    const hint = std.fmt.bufPrint(
        &hint_buf,
        "  reference in a message with @{s} so the agent loads its body.",
        .{s.name},
    ) catch "  reference with @<name>";
    try self.appendLine(.system, hint);
}

// --- Turn orchestration ----------------------------------------------------
//
// When the input fires \`on_submit\`, we append the user line,
// reserve an empty agent line, flip the spinner on, and spawn a
// worker thread that calls \`runner.run(...)\` with sinks that
// post UserEvents back into the App's main loop. The event
// handler consumes those UserEvents, mutating history in place.

/// Tag for the UserEvent payloads we post from worker threads.
/// Each variant carries owned heap-allocated slices — the main
/// loop frees them after handling. We match on event.app.name
/// to dispatch; the pointer data is cast to the matching
/// payload struct.
pub const ue_chunk = "tui.chunk";
pub const ue_tool_start = "tui.tool_start";
pub const ue_tool_progress = "tui.tool_progress";
pub const ue_tool_done = "tui.tool_done";
pub const ue_done = "tui.done";
pub const ue_error = "tui.error";
pub const ue_tick = "tui.tick";
pub const ue_ask_user = "tui.ask_user";
pub const ue_ask_user_cancel = "tui.ask_user_cancel";
pub const ue_usage = "tui.usage";
/// Per-slot timeout fired by the sub-turn watchdog. Posted with a
/// `SubturnTimeoutPayload` matching the slot key.
pub const ue_subturn_timeout = "tui.subturn_timeout";

// Every event payload carries the `turn_epoch` it was produced
// under. The main-loop handler drops payloads whose epoch no longer
// matches `Root.turn_epoch`, so a late chunk from a cancelled turn
// can't bleed into a fresh transcript. `ue_done` (which posts a
// null payload) is special-cased — see `EmptyPayload`.
/// `agent` carries the speaker name for this chunk so sub-turn replies
/// land under the sub-turn agent's pill, not under whichever agent
/// is currently "active" on the Root. Owned heap slice (duped from
/// `WorkerCtx.session_id`); freed by the handler with the payload.
pub const ChunkPayload = struct { epoch: u64, agent: []u8, text: []u8 };
pub const AskUserPayload = struct { epoch: u64, question: []u8 };
/// Tool events carry `agent` for the same reason chunks do — under
/// parallel sub-turns the active speaker on Root may not own the
/// tool, so the per-agent pending-line map needs to know which
/// agent's line to invalidate on tool boundaries. Owned heap slice;
/// freed by the handler with the payload.
pub const ToolStartPayload = struct { epoch: u64, agent: []u8, id: []u8, name: []u8, args_summary: []u8 };
pub const ToolProgressPayload = struct {
    epoch: u64,
    agent: []u8,
    id: []u8,
    /// stdout=0, stderr=1. We don't render the two streams differently
    /// today, but the field is here so a future colour pass can use it.
    stream: u8,
    chunk: []u8,
};
pub const ToolDonePayload = struct {
    epoch: u64,
    agent: []u8,
    id: []u8,
    name: []u8,
    output: []u8,
    is_error: bool,
};
pub const ErrorPayload = struct { epoch: u64, message: []u8 };
pub const UsagePayload = struct { epoch: u64, ctx_used: u64 };
/// Carries just an epoch — used by `ue_done` so the handler can
/// drop stale completions the same way it drops stale chunks.
pub const EmptyPayload = struct { epoch: u64 };

/// Posted by `postDone` when a turn completes successfully. Carries
/// the dispatch metadata echoed by the runner so the auto-dispatch
/// state machine can branch on `dispatch_kind` and the mention
/// scanner can read `output` directly (D4 forbids reconstructing
/// from transcript text). All slices are heap-owned by the payload
/// and freed by the handler — see `dropStaleIfNeeded` for the stale
/// path and the `ue_done` branch for the live path.
pub const DonePayload = struct {
    epoch: u64,
    /// Echoed from the originating `TurnRequest`. Distinguishes a
    /// primary user-triggered turn from an auto-dispatched sub-turn
    /// or invoker resume.
    dispatch_kind: harness.agent_runner.DispatchKind,
    /// For `.subturn`: the inviting agent. Owned heap slice. Null
    /// for `.primary` and `.resume_`.
    invoker: ?[]u8,
    /// Agent that ran the turn. Owned heap slice.
    target_agent: []u8,
    /// Mention-order index from the invoker's reply. 0 for primary
    /// and resume turns.
    mention_idx: u8,
    /// Final assistant text from the turn. Owned heap slice; may
    /// be empty if the turn produced no text (tool-only round, or
    /// an error path that posted done after the error).
    output: []u8,
};

/// Posted by the per-slot timeout watchdog when a sub-turn exceeds
/// its wall-clock cap. The handler matches the slot by
/// `(invoker, mention_idx, target)` and marks it `timed_out` if
/// still `in_flight`. Late `ue_done` for a timed-out slot is
/// discarded by the same triple match.
pub const SubturnTimeoutPayload = struct {
    epoch: u64,
    invoker: []u8,
    target: []u8,
    mention_idx: u8,
};

/// One in-flight sub-turn under the cross-agent auto-dispatch tree.
/// The invoker fans out one slot per known mention in its reply;
/// each slot independently transitions through the lifecycle below
/// before the invoker resume fires.
pub const SubturnSlot = struct {
    /// The agent running the sub-turn (e.g. `"sage"`). Owned heap
    /// slice — the canonical form looked up from `agent_names`.
    target: []u8,
    /// Position of this mention in the invoker's reply (left-to-
    /// right). Replies are joined back to the invoker in this order
    /// so the resume body is deterministic regardless of completion
    /// order.
    mention_idx: u8,
    /// Lifecycle stage. `in_flight` until the runner posts a
    /// matching `ue_done`; transitions to a terminal state once the
    /// reply lands or the watchdog times out. Late events for
    /// non-`in_flight` slots are dropped.
    state: State,
    /// Reply text from the sub-turn, owned heap slice. Null until
    /// `state` transitions to `done`. Used at join time.
    reply: ?[]u8 = null,
    /// Synthetic-error reason for non-`done` terminal states. Null
    /// for `in_flight` and `done`. Static string — `"timeout"`,
    /// `"runner_error"`, etc.
    error_reason: ?[]const u8 = null,

    pub const State = enum { in_flight, done, errored, cancelled, timed_out };

    /// Free `target` and `reply`. `error_reason` is a static string
    /// and must NOT be freed.
    pub fn deinit(self: *SubturnSlot, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.reply) |r| allocator.free(r);
    }
};

/// Context the worker thread carries. Allocated on heap;
/// worker frees on exit.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    app: *vxfw.App,
    message: []u8,
    session_id: []const u8,
    /// Snapshot of `Root.turn_epoch` at spawn time. Stamped on
    /// every payload this worker posts so stale events from a
    /// cancelled or superseded turn can be discarded by the
    /// main-loop handler without touching transcript state.
    epoch: u64,
    /// What kind of turn this worker is running. `primary` for a
    /// user submit, `subturn` for an auto-dispatched fan-out child,
    /// `resume_` for the invoker's resumption after join. Forwarded
    /// to the runner so the completion event echoes it back.
    dispatch_kind: harness.agent_runner.DispatchKind = .primary,
    /// For `subturn`: the inviting agent. Owned heap slice — freed
    /// by `workerMain` on exit. Null for primary/resume.
    invoker: ?[]u8 = null,
    /// For `subturn`: position of this mention in the invoker's
    /// reply. Used by the join step to order replies. 0 otherwise.
    mention_order_idx: u8 = 0,
};

/// Case-insensitive lookup against the registered agent set.
fn knowsAgent(self: *const Root, name: []const u8) bool {
    for (self.agent_names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

/// Look up the canonical (config-cased) slice for `name` from
/// `agent_names`. Returns null when the name doesn't match a known
/// agent. Used to normalise `@SAGE` and `@sage` to the same key
/// so the pending-line map doesn't double-up entries.
fn canonicalAgent(self: *const Root, name: []const u8) ?[]const u8 {
    for (self.agent_names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return n;
    }
    return null;
}

/// Find an existing pending-line key matching `name`
/// case-insensitively. Returns the canonical key already in the
/// map (its lifetime is the map's), or null if no entry exists.
fn findPendingKey(self: *Root, name: []const u8) ?[]const u8 {
    var it = self.pending_agent_lines.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.key_ptr.*;
    }
    return null;
}

/// Look up the pending agent-line index for `agent`. Returns null
/// when the agent has no open line in the current turn (either
/// never started one, just finished, or just hit a tool boundary).
fn getPendingAgentLine(self: *Root, agent: []const u8) ?usize {
    const key = self.findPendingKey(agent) orelse return null;
    return self.pending_agent_lines.get(key);
}

/// Remember `idx` as the open line for `agent`. The map owns its
/// keys — we dupe on insert and free on remove — so the chunk
/// payload's heap-owned `agent` slice can be freed by the handler
/// after this returns without dangling the map. Bounded set
/// (one entry per concurrently-streaming agent), so the alloc
/// cost is negligible.
fn setPendingAgentLine(self: *Root, agent: []const u8, idx: usize) !void {
    if (self.findPendingKey(agent)) |existing_key| {
        // Already tracking this agent — just refresh the index;
        // don't dupe a new key.
        try self.pending_agent_lines.put(self.allocator, existing_key, idx);
        return;
    }
    const key_owned = try self.allocator.dupe(u8, self.canonicalAgent(agent) orelse agent);
    errdefer self.allocator.free(key_owned);
    try self.pending_agent_lines.put(self.allocator, key_owned, idx);
}

/// Drop the pending entry for `agent`, if any. Called on tool
/// boundaries and `ue_done` so the next chunk for that agent
/// opens a fresh line below the tool block (or the previous
/// reply, if the agent speaks twice in one turn).
fn clearPendingAgentLine(self: *Root, agent: []const u8) void {
    const key = self.findPendingKey(agent) orelse return;
    if (self.pending_agent_lines.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
    }
}

/// Wipe every pending-line entry. Called on fresh user submit and
/// on turn cancel — the previous turn's bookkeeping is no longer
/// meaningful and any in-flight worker chunks were already gated
/// out by the epoch check in `dropStaleIfNeeded`.
fn clearAllPendingAgentLines(self: *Root) void {
    var it = self.pending_agent_lines.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.pending_agent_lines.clearRetainingCapacity();
}

/// Switch the active agent. Updates session_id (drives the
/// runner's request body), the header banner, and the status
/// bar. Resolves the canonical-case name from `agent_names` so
/// `@SAGE` and `@sage` both end up as `"sage"`.
fn setActiveAgent(self: *Root, name: []const u8) void {
    const canonical: []const u8 = blk: {
        for (self.agent_names) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) break :blk n;
        }
        // Fallback to the input slice — `knowsAgent` should have
        // already gated this, so we shouldn't actually hit this
        // branch in practice.
        break :blk name;
    };
    self.session_id = canonical;
    self.status_bar.agent_name = canonical;
}

fn beginTurn(self: *Root, typed: []const u8) !void {
    return self.beginTurnWithEcho(typed, typed);
}

/// Same as `beginTurn` but with split `echo` (what we display in
/// the user pill) and `body` (what we send to the runner). Used
/// by the mention router so a `@sage hi` message echoes verbatim
/// in history but ships only `hi` to sage's context.
fn beginTurnWithEcho(self: *Root, echo: []const u8, body: []const u8) !void {
    const runner = self.runner orelse return error.NoRunner;
    const app = self.app orelse return error.NoApp;

    try self.appendUserLine(echo);
    // Submitting a new turn snaps the viewport back to the live
    // tail. If the user was reviewing scrollback, their fresh
    // message — and its incoming reply — should be visible.
    self.scroll_offset = 0;
    // No pre-reserved agent line. Chunks that arrive before a
    // tool_start get a fresh agent line via the lazy path in
    // the chunk handler; chunks that arrive *after* tool lines
    // get their own agent line below the tools. This keeps the
    // reading order natural — tool calls nest between the
    // user prompt and the agent's final reply. Clearing every
    // pending entry here drops any leftover bookkeeping from a
    // previous turn whose worker chunks raced past the epoch
    // gate (rare but possible if `dropStaleIfNeeded` ran after
    // we'd already opened a line).
    self.clearAllPendingAgentLines();
    self.pending_saw_text = false;

    self.thinking.pending = true;
    self.thinking.stopping = false;
    self.status_bar.turn_stopping = false;
    self.thinking.spinner_tick = 0;
    // Rotate verb per turn via a cheap LCG; anything is fine here
    // since we just want the verb to change each time.
    self.thinking.verb_index = @intCast(@mod(vxfw.milliTimestamp(), 0xFF));
    self.thinking.elapsed_ms = 0;
    self.turn_started_ms = vxfw.milliTimestamp();
    self.current_turn_id +%= 1;
    self.turn_epoch +%= 1;
    // Fresh user submit clobbers any in-flight auto-dispatch tree.
    // Stale sub-turns from the previous fan-out — if any were still
    // running — will be dropped by the epoch gate when their
    // `ue_done` lands; their slot state is gone.
    self.clearSubturnState();

    // Note: we do NOT kick the tick chain via `app.loop.postEvent(.tick)`
    // here — App.run holds the queue mutex while iterating drained events,
    // so re-entering postEvent from inside a key_press handler deadlocks
    // on the (non-recursive) pthread mutex. The caller (eventHandler in
    // Root) re-arms the tick chain via `ctx.tick(0, …)` after this returns,
    // which routes through the cmd list / timers and bypasses the queue.

    // Dup the message so the worker owns it independent of the
    // input buffer (which clears right after on_submit returns).
    // If peers replied since the last user message, prepend their
    // text so the active agent has full context. The chatter buffer
    // owns the slice we drained — we move it into `message_copy`
    // by concatenation, then free the original.
    const message_copy = blk: {
        if (self.drainPeerChatter()) |chatter| {
            defer self.allocator.free(chatter);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{s}\n\n---\n{s}",
                .{ chatter, body },
            );
        }
        break :blk try self.allocator.dupe(u8, body);
    };
    errdefer self.allocator.free(message_copy);

    const ctx = try self.allocator.create(WorkerCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .root = self,
        .app = app,
        .message = message_copy,
        .session_id = self.session_id,
        .epoch = self.turn_epoch,
    };
    _ = runner;

    var thread = try std.Thread.spawn(.{}, workerMain, .{ctx});
    thread.detach();
}

fn workerMain(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.message);
        if (ctx.invoker) |s| ctx.allocator.free(s);
        ctx.allocator.destroy(ctx);
    }

    const runner = ctx.root.runner orelse {
        postError(ctx, "no runner");
        postDone(ctx, null);
        return;
    };

    const result = runner.run(.{
        .session_id = ctx.session_id,
        .target_agent = ctx.session_id,
        .input = ctx.message,
        .turn_epoch = ctx.epoch,
        .dispatch_kind = ctx.dispatch_kind,
        .invoker = ctx.invoker,
        .mention_order_idx = ctx.mention_order_idx,
        .stream_sink = chunkSink,
        .stream_sink_ctx = @ptrCast(ctx),
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = @ptrCast(ctx),
    }) catch |err| {
        const message = switch (err) {
            error.GatewayDown => "gateway unreachable; start tigerclaw gateway",
            error.Interrupted, error.Cancelled => "turn cancelled",
            else => @errorName(err),
        };
        postError(ctx, message);
        postDone(ctx, null);
        return;
    };
    postUsage(ctx, result.usage.contextTokens());
    postDone(ctx, result);
}

fn postUsage(ctx: *WorkerCtx, ctx_used: u64) void {
    const payload = ctx.allocator.create(UsagePayload) catch return;
    payload.* = .{ .epoch = ctx.epoch, .ctx_used = ctx_used };
    postUserEvent(ctx, ue_usage, payload);
}

// Runner sinks — run on the worker thread. Each one heap-
// allocates a payload struct, attaches it to a \`UserEvent\`, and
// posts to the main loop. The loop's event handler casts the
// pointer back and frees.

fn chunkSink(sink_ctx: ?*anyopaque, fragment: []const u8) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    const payload = ctx.allocator.create(ChunkPayload) catch return;
    const agent_dup = ctx.allocator.dupe(u8, ctx.session_id) catch {
        ctx.allocator.destroy(payload);
        return;
    };
    const text_dup = ctx.allocator.dupe(u8, fragment) catch {
        ctx.allocator.free(agent_dup);
        ctx.allocator.destroy(payload);
        return;
    };
    payload.* = .{
        .epoch = ctx.epoch,
        .agent = agent_dup,
        .text = text_dup,
    };
    postUserEvent(ctx, ue_chunk, payload);
}

fn toolEventSink(
    sink_ctx: ?*anyopaque,
    event: harness.agent_runner.ToolEvent,
) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    switch (event) {
        .started => |s| {
            const payload = ctx.allocator.create(ToolStartPayload) catch return;
            const agent_dup = ctx.allocator.dupe(u8, ctx.session_id) catch {
                ctx.allocator.destroy(payload);
                return;
            };
            payload.* = .{
                .epoch = ctx.epoch,
                .agent = agent_dup,
                .id = ctx.allocator.dupe(u8, s.id) catch {
                    ctx.allocator.free(agent_dup);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, s.name) catch {
                    ctx.allocator.free(payload.agent);
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
                // Dupe even when empty so the consumer can free
                // unconditionally without branching on length.
                .args_summary = ctx.allocator.dupe(u8, s.args_summary) catch {
                    ctx.allocator.free(payload.agent);
                    ctx.allocator.free(payload.id);
                    ctx.allocator.free(payload.name);
                    ctx.allocator.destroy(payload);
                    return;
                },
            };
            postUserEvent(ctx, ue_tool_start, payload);
        },
        .progress => |pr| {
            const payload = ctx.allocator.create(ToolProgressPayload) catch return;
            const agent_dup = ctx.allocator.dupe(u8, ctx.session_id) catch {
                ctx.allocator.destroy(payload);
                return;
            };
            payload.* = .{
                .epoch = ctx.epoch,
                .agent = agent_dup,
                .id = ctx.allocator.dupe(u8, pr.id) catch {
                    ctx.allocator.free(agent_dup);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .stream = switch (pr.stream) {
                    .stdout => 0,
                    .stderr => 1,
                },
                .chunk = ctx.allocator.dupe(u8, pr.chunk) catch {
                    ctx.allocator.free(payload.agent);
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
            };
            postUserEvent(ctx, ue_tool_progress, payload);
        },
        .finished => |f| {
            const preview = tool_preview.render(ctx.allocator, f.name, f.kind) catch
                ctx.allocator.dupe(u8, f.kind.flatText()) catch return;
            const payload = ctx.allocator.create(ToolDonePayload) catch {
                ctx.allocator.free(preview);
                return;
            };
            const agent_dup = ctx.allocator.dupe(u8, ctx.session_id) catch {
                ctx.allocator.free(preview);
                ctx.allocator.destroy(payload);
                return;
            };
            payload.* = .{
                .epoch = ctx.epoch,
                .agent = agent_dup,
                .id = ctx.allocator.dupe(u8, f.id) catch {
                    ctx.allocator.free(preview);
                    ctx.allocator.free(agent_dup);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, f.name) catch {
                    ctx.allocator.free(preview);
                    ctx.allocator.free(payload.agent);
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .output = preview,
                .is_error = f.is_error,
            };
            postUserEvent(ctx, ue_tool_done, payload);
        },
    }
}

fn postError(ctx: *WorkerCtx, message: []const u8) void {
    const payload = ctx.allocator.create(ErrorPayload) catch return;
    payload.* = .{
        .epoch = ctx.epoch,
        .message = ctx.allocator.dupe(u8, message) catch {
            ctx.allocator.destroy(payload);
            return;
        },
    };
    postUserEvent(ctx, ue_error, payload);
}

/// Post a turn-completion event. `result` carries the runner's
/// echoed dispatch metadata plus the final assistant text so the
/// auto-dispatch state machine can branch on `dispatch_kind` and
/// scan `output` directly. Pass `null` from error paths where the
/// runner never returned a result; the handler then renders error
/// state but does NOT scan or fan out (a failed primary turn does
/// not auto-dispatch).
fn postDone(ctx: *WorkerCtx, result: ?harness.agent_runner.TurnResult) void {
    const r = result orelse {
        // Error path: post a stub payload that's `dispatch_kind=primary`
        // with empty output. The handler's mention scan returns 0 and
        // no fan-out fires.
        const payload = ctx.allocator.create(DonePayload) catch return;
        payload.* = .{
            .epoch = ctx.epoch,
            .dispatch_kind = ctx.dispatch_kind,
            .invoker = if (ctx.invoker) |s| ctx.allocator.dupe(u8, s) catch null else null,
            .target_agent = ctx.allocator.dupe(u8, ctx.session_id) catch {
                ctx.allocator.destroy(payload);
                return;
            },
            .mention_idx = ctx.mention_order_idx,
            .output = ctx.allocator.dupe(u8, "") catch {
                ctx.allocator.free(payload.target_agent);
                ctx.allocator.destroy(payload);
                return;
            },
        };
        postUserEvent(ctx, ue_done, payload);
        return;
    };

    const payload = ctx.allocator.create(DonePayload) catch return;
    const target_dup = ctx.allocator.dupe(u8, if (r.target_agent.len != 0) r.target_agent else ctx.session_id) catch {
        ctx.allocator.destroy(payload);
        return;
    };
    errdefer ctx.allocator.free(target_dup);
    const output_dup = ctx.allocator.dupe(u8, r.output) catch {
        ctx.allocator.free(target_dup);
        ctx.allocator.destroy(payload);
        return;
    };
    errdefer ctx.allocator.free(output_dup);
    const invoker_dup: ?[]u8 = if (r.invoker) |s| (ctx.allocator.dupe(u8, s) catch null) else null;
    payload.* = .{
        .epoch = ctx.epoch,
        .dispatch_kind = r.dispatch_kind,
        .invoker = invoker_dup,
        .target_agent = target_dup,
        .mention_idx = r.mention_order_idx,
        .output = output_dup,
    };
    postUserEvent(ctx, ue_done, payload);
}

fn postUserEvent(ctx: *WorkerCtx, name: []const u8, data: ?*const anyopaque) void {
    const loop = ctx.app.loop orelse {
        // App loop is gone — nothing we can do. Leak the payload;
        // the process is probably tearing down anyway.
        return;
    };
    loop.postEvent(.{ .app = .{ .name = name, .data = data } });
}

/// Append a plain text line to the history, taking ownership
/// of a heap-allocated copy of `text`. Used to seed demo data
/// while the runner integration is still in flight.
pub fn appendLine(self: *Root, role: tui.Line.Role, text: []const u8) !void {
    return self.appendLineWithSpeaker(role, text, null);
}

/// Append a line and stamp it with a speaker name. The name is
/// duped onto the line; null leaves `speaker` unset (system / tool
/// rows don't get pills).
pub fn appendLineWithSpeaker(
    self: *Root,
    role: tui.Line.Role,
    text: []const u8,
    speaker: ?[]const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, text);

    const speaker_owned: ?[]u8 = if (speaker) |s|
        try self.allocator.dupe(u8, s)
    else
        null;
    errdefer if (speaker_owned) |s| self.allocator.free(s);

    try self.history.append(self.allocator, .{
        .role = role,
        .text = buf,
        .speaker = speaker_owned,
    });
}

/// Convenience: append a `.user` line stamped with `self.user_name`.
pub fn appendUserLine(self: *Root, text: []const u8) !void {
    return self.appendLineWithSpeaker(.user, text, self.user_name);
}

/// Embedded TIGERCLAW wordmarks — wide and compact variants
/// inherited from the old pinned Header widget. Both are six
/// rows tall; the wide form is ~71 display columns, the compact
/// "TC" form is ~17. `appendBanner` picks based on terminal
/// width so a narrow pane doesn't paint a wordmark that wraps.
const banner_wordmark_wide = @embedFile("wordmark.txt");
const banner_wordmark_tc = @embedFile("wordmark_tc.txt");

/// Minimum terminal width that triggers the wide wordmark. Below
/// this we fall back to the compact "TC" form. Matches the old
/// `Header.wide_min_width` (72 wordmark cols + 4 cells of margin).
const banner_wide_min_width: u16 = 76;

/// Emit the scrolling banner at the top of history. Six wordmark
/// rows in gradient + a one-line tigerclaw info line tinted as
/// `.system`. Idempotent — safe to call once after `init`. The
/// banner scrolls along with the rest of the chat; once a real
/// turn fills the pane, the banner moves out of view. `width` is
/// the launch-time terminal column count; pass 0 to default to
/// the wide variant.
pub fn appendBanner(self: *Root, width: u16) !void {
    const wordmark = if (width == 0 or width >= banner_wide_min_width)
        banner_wordmark_wide
    else
        banner_wordmark_tc;

    var row_idx: u8 = 0;
    var line_iter = std.mem.splitScalar(u8, wordmark, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, line);
        try self.history.append(self.allocator, .{
            .role = .banner,
            .text = buf,
            .banner_row = row_idx,
        });
        row_idx += 1;
    }

    // One-line info row beneath the wordmark: `tigerclaw <version> ·
    // <agent>`. Painted via the `.system` palette (the banner
    // gradient only covers wordmark rows). The user's first turn
    // pushes both the wordmark and this line off-screen as the
    // chat grows.
    const info = try std.fmt.allocPrint(
        self.allocator,
        "tigerclaw {s} · {s}",
        .{ build_options.version, self.session_id },
    );
    defer self.allocator.free(info);
    try self.appendLine(.system, info);
}

/// Convenience: append a `.agent` line stamped with the active
/// agent (today: `self.session_id`).
pub fn appendAgentLine(self: *Root, text: []const u8) !void {
    return self.appendLineWithSpeaker(.agent, text, self.session_id);
}

/// Build the framed body sent to a sub-turn agent. Tells the callee
/// who invited it and pastes the invoker's reply verbatim. Caller
/// owns the returned heap slice.
///
/// Format (D5):
///
///     @<invoker> mentioned you in their reply to the user. Their full
///     reply follows. Respond to <invoker>; the user will see your reply.
///
///     ---
///     <verbatim invoker reply>
pub fn subturnFrame(
    allocator: std.mem.Allocator,
    invoker: []const u8,
    invoker_reply: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "@{s} mentioned you in their reply to the user. " ++
            "Their full reply follows. Respond to {s}; the user " ++
            "will see your reply.\n\n---\n{s}",
        .{ invoker, invoker, invoker_reply },
    );
}

/// Append a one-line system marker showing the dispatch chain so
/// the user sees the escalation in real time:
///
///     ↳ @tiger → @sage
pub fn appendSubturnMarker(
    self: *Root,
    invoker: []const u8,
    target: []const u8,
) !void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "↳ @{s} → @{s}",
        .{ invoker, target },
    ) catch "↳ subturn dispatch";
    try self.appendLine(.system, line);
}

/// Spawn a worker thread that runs a sub-turn for `target`, framed
/// as if `invoker` had asked it. Increments `pending_subturns` so
/// the auto-dispatch state machine knows when to fire the join.
/// Also spawns a per-slot timeout watchdog that posts
/// `ue_subturn_timeout` after `auto_dispatch_subturn_timeout_secs`
/// — the handler ignores it if the slot already completed.
pub fn dispatchSubturn(
    self: *Root,
    invoker: []const u8,
    target: []const u8,
    mention_idx: u8,
    invoker_reply: []const u8,
) !void {
    dispatch_log.info("dispatchSubturn: invoker=@{s} target=@{s} idx={d} reply_bytes={d} app={s} runner={s}", .{
        invoker,
        target,
        mention_idx,
        invoker_reply.len,
        if (self.app == null) "null" else "set",
        if (self.runner == null) "null" else "set",
    });

    // No marker line — the sub-turn agent's reply lands with its
    // own speaker pill, which is sufficient indication that another
    // agent is now contributing. Earlier prototypes emitted a
    // `↳ @invoker → @target` system row here; it read as debug
    // noise rather than chat.

    // Resolve canonical target casing from the registered set so
    // routing matches `agent_registry`'s lookup key.
    const target_canonical: []const u8 = blk: {
        for (self.agent_names) |n| {
            if (std.ascii.eqlIgnoreCase(n, target)) break :blk n;
        }
        break :blk target;
    };

    // Record the slot first so a fast-completing worker can't post
    // `ue_done` and underflow `pending_subturns` before we track it.
    // Tests rely on this happening even when `app`/`runner` are null;
    // they drive completions synthetically through `handleUserEvent`.
    try self.subturn_slots.append(self.allocator, .{
        .target = try self.allocator.dupe(u8, target_canonical),
        .mention_idx = mention_idx,
        .state = .in_flight,
    });
    self.pending_subturns += 1;

    // No app/runner attached → bookkeeping-only mode. Tests path.
    const app = self.app orelse return;
    if (self.runner == null) return;

    const body = try subturnFrame(self.allocator, invoker, invoker_reply);
    errdefer self.allocator.free(body);

    const invoker_owned = try self.allocator.dupe(u8, invoker);
    errdefer self.allocator.free(invoker_owned);

    const ctx = try self.allocator.create(WorkerCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .root = self,
        .app = app,
        .message = body,
        .session_id = target_canonical,
        .epoch = self.turn_epoch,
        .dispatch_kind = .subturn,
        .invoker = invoker_owned,
        .mention_order_idx = mention_idx,
    };

    var thread = try std.Thread.spawn(.{}, workerMain, .{ctx});
    thread.detach();

    // Per-slot timeout watchdog. On its own thread so a stuck
    // provider call can't hold up the timeout. Failure to spawn
    // is non-fatal — the slot just runs without a wall-clock cap,
    // which is what we had pre-watchdog.
    self.spawnSubturnTimeout(invoker, target_canonical, mention_idx) catch {};
}

/// Heap-owned context the timeout watchdog carries. The watchdog
/// owns every field; `timeoutWatchdog` frees the lot before exit.
const SubturnTimeoutCtx = struct {
    allocator: std.mem.Allocator,
    app: *vxfw.App,
    epoch: u64,
    timeout_ns: u64,
    invoker: []u8,
    target: []u8,
    mention_idx: u8,
};

fn spawnSubturnTimeout(
    self: *Root,
    invoker: []const u8,
    target: []const u8,
    mention_idx: u8,
) !void {
    // 0 means "no timeout" — skip the watchdog spawn entirely so a
    // long-running peer (large file write, slow bash, upload) isn't
    // marked timed_out mid-flight. The slot still resolves on the
    // peer's natural `ue_done`, and the user can `/stop <agent>` at
    // any point to abort manually.
    if (self.auto_dispatch_subturn_timeout_secs == 0) return;

    const app = self.app orelse return error.NoApp;
    const ctx = try self.allocator.create(SubturnTimeoutCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .app = app,
        .epoch = self.turn_epoch,
        .timeout_ns = @as(u64, self.auto_dispatch_subturn_timeout_secs) * std.time.ns_per_s,
        .invoker = try self.allocator.dupe(u8, invoker),
        .target = try self.allocator.dupe(u8, target),
        .mention_idx = mention_idx,
    };
    errdefer ctx.allocator.free(ctx.invoker);
    errdefer ctx.allocator.free(ctx.target);

    var thread = try std.Thread.spawn(.{}, timeoutWatchdog, .{ctx});
    thread.detach();
}

fn timeoutWatchdog(ctx: *SubturnTimeoutCtx) void {
    defer {
        ctx.allocator.free(ctx.invoker);
        ctx.allocator.free(ctx.target);
        ctx.allocator.destroy(ctx);
    }

    // Sleep on the wall clock. `nanosleep` handles spurious wake;
    // we don't bother because timeout precision here is "around
    // 120 seconds", not microseconds.
    var req: std.c.timespec = .{
        .sec = @intCast(ctx.timeout_ns / std.time.ns_per_s),
        .nsec = @intCast(ctx.timeout_ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);

    const loop = ctx.app.loop orelse return;
    const payload = ctx.allocator.create(SubturnTimeoutPayload) catch return;
    payload.* = .{
        .epoch = ctx.epoch,
        .invoker = ctx.allocator.dupe(u8, ctx.invoker) catch {
            ctx.allocator.destroy(payload);
            return;
        },
        .target = ctx.allocator.dupe(u8, ctx.target) catch {
            ctx.allocator.free(payload.invoker);
            ctx.allocator.destroy(payload);
            return;
        },
        .mention_idx = ctx.mention_idx,
    };
    loop.postEvent(.{ .app = .{ .name = ue_subturn_timeout, .data = payload } });
}

/// Build the join body sent back to the invoker on resume. Slots are
/// already in mention-order because `scanAndFanOut` appends them
/// left-to-right; the body preserves that order regardless of which
/// sub-turn finished first. Per D6: each slot becomes a paragraph
/// led by `@<target> replied:` so the resume re-scan (D4) can
/// recognize the synthetic header and skip it. Slots that ended in
/// a non-`.done` terminal state contribute a synthetic error line
/// instead, so the invoker still sees something for every mention.
///
/// Caller owns the returned heap slice.
pub fn buildResumeBody(
    allocator: std.mem.Allocator,
    slots: []const SubturnSlot,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (slots, 0..) |slot, i| {
        if (i > 0) try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, "@");
        try buf.appendSlice(allocator, slot.target);
        try buf.appendSlice(allocator, " replied:\n");

        switch (slot.state) {
            .done => {
                if (slot.reply) |r| {
                    try buf.appendSlice(allocator, r);
                } else {
                    // `done` without a reply shouldn't happen in
                    // practice; treat as empty rather than crash.
                    try buf.appendSlice(allocator, "");
                }
            },
            .timed_out, .errored, .cancelled => {
                const reason = slot.error_reason orelse "unknown error";
                var rbuf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &rbuf,
                    "Error: @{s} did not respond ({s})",
                    .{ slot.target, reason },
                ) catch "Error: subturn failed";
                try buf.appendSlice(allocator, line);
            },
            .in_flight => {
                // Reaching here means the join fired with slots
                // still pending — a logic bug. Fall back to a
                // synthetic message so the invoker isn't lied to.
                var rbuf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &rbuf,
                    "Error: @{s} reply not received",
                    .{slot.target},
                ) catch "Error: missing subturn reply";
                try buf.appendSlice(allocator, line);
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Spawn a `.resume_` worker that delivers the join body to the
/// paused invoker. Similar shape to `dispatchSubturn` minus the
/// slot bookkeeping — resume is a singleton turn, not a fan-out
/// member. Increments `auto_dispatch_calls` for budget accounting
/// (step 7 will enforce the cap; for now the field just tracks).
fn dispatchResume(self: *Root, invoker: []const u8, body: []u8) !void {
    // Resolve canonical invoker casing from the registered set so
    // the gateway routes to the right runner.
    const invoker_canonical: []const u8 = blk: {
        for (self.agent_names) |n| {
            if (std.ascii.eqlIgnoreCase(n, invoker)) break :blk n;
        }
        break :blk invoker;
    };

    self.auto_dispatch_calls +%= 1;

    // No app attached → tests path. Stash the body on `Root` so
    // the test harness can inspect it; production never hits this.
    const app = self.app orelse {
        if (self.last_resume_body) |old| self.allocator.free(old);
        self.last_resume_body = body;
        return;
    };

    // Take ownership of `body` unconditionally — even on the
    // spawn-failure path. `maybeResume` cannot tell from outside
    // whether the worker started; centralizing the free here keeps
    // the lifecycle one-sided.
    errdefer self.allocator.free(body);

    const ctx = try self.allocator.create(WorkerCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .root = self,
        .app = app,
        .message = body,
        .session_id = invoker_canonical,
        .epoch = self.turn_epoch,
        .dispatch_kind = .resume_,
        .invoker = null,
        .mention_order_idx = 0,
    };

    // Worker now owns `body` (via `ctx.message`); cancel the
    // errdefer by exiting through the success path.
    var thread = try std.Thread.spawn(.{}, workerMain, .{ctx});
    thread.detach();
}

/// Drain fan-out state once all sub-turns reach a terminal state.
/// Originally this fired a synthesizing resume back at the invoker
/// (tiger sees `@sage replied: ...` and writes a follow-up). In the
/// peer-chat model the user wants, sub-turn replies *are* the
/// agent's contribution to the conversation — the invoker doesn't
/// need to summarize them. So this just cleans up state and stops.
///
/// `dispatchResume` and `buildResumeBody` are kept around (currently
/// dead at runtime) in case a future "synthesize for me" UX flag
/// wants the old behavior back.
/// Hard cap on the peer-chatter buffer. Without it, each fan-out
/// round appends one `[<agent> said]\n<text>` block and the next
/// user submit prepends the entire history of replies — a chatty
/// 20-turn debate accumulates tens of KB that ride into every new
/// turn. Cap at 32 KiB: enough for several full peer replies in a
/// single turn, small enough that an unattended runaway can't
/// silently push the request body into provider rate-limit
/// territory. When the cap would be exceeded we drop oldest blocks
/// FIFO; if even the new block alone overflows, it is truncated.
const peer_chatter_cap: usize = 32 * 1024;

/// Add a sub-turn reply to the pending peer-chatter buffer. Format
/// each block as `[<agent> said]\n<text>` separated by a blank line.
/// The buffer is consumed and cleared on the next user submit
/// (`drainPeerChatter`). Total size is bounded by `peer_chatter_cap`.
fn appendPeerChatter(self: *Root, agent: []const u8, text: []const u8) !void {
    if (text.len == 0) return;

    // Build the new block first so we know its size.
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(self.allocator);
    try block.appendSlice(self.allocator, "[");
    try block.appendSlice(self.allocator, agent);
    try block.appendSlice(self.allocator, " said]\n");
    try block.appendSlice(self.allocator, text);

    // Truncate the new block to the cap (with a "[...truncated]"
    // marker) when it alone would overflow. The marker preserves
    // semantic clarity downstream — the active agent sees that the
    // peer's reply was longer than the buffer allowed.
    const trunc_marker = "\n[...truncated]";
    if (block.items.len > peer_chatter_cap) {
        const keep_head = peer_chatter_cap - trunc_marker.len;
        block.shrinkRetainingCapacity(keep_head);
        try block.appendSlice(self.allocator, trunc_marker);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);

    if (self.peer_chatter) |existing| {
        // Drop oldest blocks (FIFO) until appending the new block
        // (plus its `\n\n` separator) fits within the cap. Blocks
        // are separated by a blank line — find the first "\n\n["
        // and slice from there. If the existing buffer can't be
        // pruned to fit (single huge block), drop it entirely.
        var keep: []const u8 = existing;
        const sep_overhead = if (keep.len > 0) @as(usize, 2) else 0;
        while (keep.len + sep_overhead + block.items.len > peer_chatter_cap and keep.len > 0) {
            if (std.mem.indexOf(u8, keep, "\n\n[")) |idx| {
                keep = keep[idx + 2 ..];
            } else {
                keep = "";
                break;
            }
        }
        if (keep.len > 0) {
            try buf.appendSlice(self.allocator, keep);
            try buf.appendSlice(self.allocator, "\n\n");
        }
    }

    try buf.appendSlice(self.allocator, block.items);

    if (self.peer_chatter) |old| self.allocator.free(old);
    self.peer_chatter = try buf.toOwnedSlice(self.allocator);
}

/// Take ownership of any buffered peer chatter. Returns null when
/// no peers have spoken since the last drain. The returned slice is
/// caller-owned; the buffer is cleared.
fn drainPeerChatter(self: *Root) ?[]u8 {
    const out = self.peer_chatter orelse return null;
    self.peer_chatter = null;
    return out;
}

fn maybeResume(self: *Root) !void {
    if (self.pending_subturns != 0) return;
    if (self.invoker_to_resume == null) return;

    for (self.subturn_slots.items) |*slot| slot.deinit(self.allocator);
    self.subturn_slots.clearRetainingCapacity();
    if (self.invoker_to_resume) |s| self.allocator.free(s);
    self.invoker_to_resume = null;
}

/// Find the `.in_flight` sub-turn slot matching this completion
/// triple. Returns null if no slot is in flight for that key —
/// meaning either we never dispatched it (shouldn't happen), it was
/// already marked terminal by the timeout watchdog (race), or the
/// fan-out tree was reset by a fresh user submit (handled by the
/// epoch gate before we reach here, so this branch is mostly defensive).
fn findSubturnSlot(
    self: *Root,
    invoker: []const u8,
    target: []const u8,
    mention_idx: u8,
) ?*SubturnSlot {
    for (self.subturn_slots.items) |*slot| {
        if (slot.state != .in_flight) continue;
        if (slot.mention_idx != mention_idx) continue;
        if (!std.ascii.eqlIgnoreCase(slot.target, target)) continue;
        // The invoker is implicit — there's only one fan-out tree
        // in flight per user-turn — but matching it explicitly
        // makes the lookup robust against any future change that
        // allows nested invocations.
        if (self.invoker_to_resume) |inv| {
            if (!std.ascii.eqlIgnoreCase(inv, invoker)) continue;
        }
        return slot;
    }
    return null;
}

/// Sub-turn completion: stash the reply, mark the slot done, and if
/// no slots remain in-flight, the join+resume step (commit 6) takes
/// over. Today we just record the state so the join has data to
/// work with.
fn onSubturnDone(self: *Root, p: *const DonePayload) !void {
    dispatch_log.info("onSubturnDone: target=@{s} invoker=@{s} idx={d} output_bytes={d}", .{
        p.target_agent,
        if (p.invoker) |s| s else "<null>",
        p.mention_idx,
        p.output.len,
    });
    const invoker = p.invoker orelse {
        dispatch_log.warn("onSubturnDone: missing invoker — sub-turn metadata corrupt", .{});
        return;
    };
    const slot = self.findSubturnSlot(invoker, p.target_agent, p.mention_idx) orelse {
        dispatch_log.warn("onSubturnDone: no matching slot for (@{s},@{s},{d})", .{ invoker, p.target_agent, p.mention_idx });
        return;
    };
    slot.reply = try self.allocator.dupe(u8, p.output);
    slot.state = .done;
    if (self.pending_subturns > 0) self.pending_subturns -= 1;
    dispatch_log.info("onSubturnDone: slot @{s} marked done; pending_subturns now {d}", .{ p.target_agent, self.pending_subturns });

    // Append this sub-turn's reply to `peer_chatter` so the next
    // user submit prepends it to the runner body — that's how the
    // active agent finds out what its peers said. No new model call
    // and no per-agent persistence layer; the user's next message
    // carries the context as plain text.
    self.appendPeerChatter(p.target_agent, p.output) catch |e| {
        dispatch_log.warn("appendPeerChatter failed: {s}", .{@errorName(e)});
    };
    // If this was the last in-flight slot, fire the join + resume.
    // The invoker's resumed reply re-enters `scanAndFanOut` via the
    // normal `ue_done` path, so cascading mentions just keep looping
    // until either no fresh mentions appear or the budget halts it.
    self.maybeResume() catch |e| {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "! resume dispatch failed: {s}",
            .{@errorName(e)},
        ) catch "! resume dispatch failed";
        self.appendLine(.system, line) catch {};
    };

    // Sub-turn replies can also mention peers — that's how the
    // hand-off pattern (`@tiger over to you`) keeps the conversation
    // bouncing. Scan the sub-turn's output the same way we scan a
    // primary reply. The model-call budget bounds runaway cascades.
    self.scanAndFanOut(p) catch |e| {
        dispatch_log.warn("scanAndFanOut after subturn failed: {s}", .{@errorName(e)});
    };
}

/// Primary or resume completion: scan the assistant's final text
/// for known agent mentions and fan out one sub-turn per mention.
/// `output` is `TurnResult.output` straight from the runner — never
/// reconstructed from transcript text (D4).
///
/// Budget enforcement (D7): the auto-dispatch tree per user-turn
/// can spend at most `auto_dispatch_max_calls` model calls across
/// sub-turns and resumes. Each dispatch consumes one. When the
/// caller's mention list would push us past the cap, we dispatch
/// up to the remaining quota and append a system line listing the
/// skipped mentions plus the remaining quota — and we still need
/// to budget for the eventual resume, so the per-call check
/// reserves one slot for it.
fn scanAndFanOut(self: *Root, p: *const DonePayload) !void {
    dispatch_log.info("scanAndFanOut: target=@{s} kind={s} output_bytes={d} agents={d} epoch={d}", .{
        p.target_agent,
        @tagName(p.dispatch_kind),
        p.output.len,
        self.agent_names.len,
        p.epoch,
    });

    // No agent set, no mentions to scan against. Common in tests.
    if (self.agent_names.len == 0) {
        dispatch_log.info("scanAndFanOut: skip — no agent_names registered", .{});
        return;
    }
    if (p.output.len == 0) {
        dispatch_log.info("scanAndFanOut: skip — empty output", .{});
        return;
    }

    // The invoker for the new fan-out is whichever agent just spoke.
    const invoker = p.target_agent;
    const matches = mention.findAll(self.allocator, p.output, self.agent_names, invoker) catch return;
    defer self.allocator.free(matches);
    dispatch_log.info("scanAndFanOut: invoker=@{s} matches={d}", .{ invoker, matches.len });
    for (matches) |m| dispatch_log.info("  match @{s}", .{m.name});
    if (matches.len == 0) return;

    // Reserve one budget slot for the resume that will fire after
    // these sub-turns drain. Without this, we could dispatch N
    // sub-turns up to the cap and then fail to resume the invoker —
    // stranding the conversation halfway.
    const used: u32 = self.auto_dispatch_calls;
    const cap: u32 = self.auto_dispatch_max_calls;
    if (used + 1 >= cap) {
        // Not enough budget even for the resume; halt the whole
        // fan-out and tell the user.
        try self.appendBudgetHaltLine(matches, 0);
        return;
    }
    const room_for_subturns: u32 = cap - used - 1; // reserve one for resume
    const dispatch_count: usize = @min(matches.len, room_for_subturns);

    if (self.invoker_to_resume) |old| self.allocator.free(old);
    self.invoker_to_resume = try self.allocator.dupe(u8, invoker);

    for (matches[0..dispatch_count], 0..) |m, idx| {
        // `dispatchSubturn` increments `pending_subturns` and
        // appends the slot before spawning so a fast worker can't
        // race past us.
        self.dispatchSubturn(invoker, m.name, @intCast(idx), p.output) catch |e| {
            // Log via system row; keep going — partial fan-out is
            // better than dropping the whole tree on one error.
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "! subturn dispatch failed for @{s}: {s}",
                .{ m.name, @errorName(e) },
            ) catch "! subturn dispatch failed";
            self.appendLine(.system, line) catch {};
            continue;
        };
        self.auto_dispatch_calls +%= 1;
    }

    if (dispatch_count < matches.len) {
        try self.appendBudgetHaltLine(matches, dispatch_count);
    }
}

/// Emit a one-line system marker explaining the dispatch budget
/// halt. `dispatched` is how many of `matches` we did fan out;
/// the rest are listed as skipped.
fn appendBudgetHaltLine(
    self: *Root,
    matches: []const mention.Match,
    dispatched: usize,
) !void {
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "! dispatch budget reached ({d}/{d}); skipped:",
        .{ self.auto_dispatch_calls, self.auto_dispatch_max_calls },
    ) catch "! dispatch budget reached; skipped:";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, head);
    var first = true;
    for (matches[dispatched..]) |m| {
        if (first) {
            try buf.appendSlice(self.allocator, " @");
            first = false;
        } else {
            try buf.appendSlice(self.allocator, ", @");
        }
        try buf.appendSlice(self.allocator, m.name);
    }
    try self.appendLine(.system, buf.items);
}

pub fn widget(self: *Root) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = eventHandler,
        .drawFn = drawFn,
    };
}

fn eventHandler(
    ptr: *anyopaque,
    ctx: *vxfw.EventContext,
    event: vxfw.Event,
) anyerror!void {
    const self: *Root = @ptrCast(@alignCast(ptr));
    switch (event) {
        // Bracketed paste — forward to the input widget so its
        // stash-to-file logic kicks in. Without this branch the
        // event drops on Root's floor and a megabyte of pasted
        // text never reaches the buffer.
        .paste => {
            try self.input.widget().handleEvent(ctx, event);
            return;
        },
        // Bracketing markers — forward so the input widget can
        // enter/exit its paste-accumulation mode. Between
        // paste_start and paste_end, terminals send the pasted
        // bytes as ordinary key_press events; the input widget
        // batches those into one big paste so the stash-to-file
        // threshold fires once at paste_end instead of inserting
        // thousands of one-char inserts into the live edit buffer.
        .paste_start, .paste_end => {
            try self.input.widget().handleEvent(ctx, event);
            ctx.consumeAndRedraw();
            return;
        },
        .key_press => |key| {
            // Bracketed-paste body: between paste_start and
            // paste_end every keystroke belongs to the paste, not
            // to the user. Skip Root's chord/scrollback handling
            // entirely so things like ESC, page-up, and Ctrl-C
            // inside the pasted text don't fire chat actions.
            if (self.input.in_bracketed_paste) {
                try self.input.widget().handleEvent(ctx, event);
                return;
            }

            // Hard-quit chord: Ctrl-C / Ctrl-Q. Plain `q`
            // no longer quits now that the input box is live —
            // it's a valid character to type in a message.
            if (key.matches('c', .{ .ctrl = true }) or
                key.matches('q', .{ .ctrl = true }))
            {
                ctx.quit = true;
                return;
            }

            // ESC during a pending turn cooperatively cancels.
            // Defers to the slash-menu escape handler below when
            // a slash is being typed (Esc closes the menu first);
            // otherwise reaches the runner's cancel hook so the
            // streaming reader and tool dispatch loop pick up the
            // flag at their next checkpoint.
            const esc_pending_turn =
                self.runner != null and
                self.turn_started_ms != 0 and
                !(self.input.buf.items.len > 0 and self.input.buf.items[0] == '/') and
                key.matches(vaxis.Key.escape, .{});
            if (esc_pending_turn) {
                // Cancel-storm guard: only the first ESC of a turn
                // fires the runner cancel hook. Subsequent ESC
                // presses (or held-key auto-repeat) are absorbed —
                // without this, every keystroke spawns a fresh
                // DELETE /sessions/:id/turns/current thread on the
                // gateway runner and floods the wire.
                if (!self.thinking.stopping) {
                    self.thinking.stopping = true;
                    self.status_bar.turn_stopping = true;
                    self.hint.left = "stopping turn  ·  waiting for gateway cancel";
                    try self.appendLine(.system, "∙ stopping turn…");
                    self.runner.?.cancel(0);
                }
                // If the agent was in an ask_user wait, clear the
                // UI-side pending flag here (we're already on the
                // UI thread). The runner's ask_user worker will
                // observe the cancel flag on its 50ms tick and
                // return a "[cancelled]" tool_result; in the
                // meantime the user's next keystroke shouldn't be
                // captured as a stale reply, so reset the gate.
                if (self.ask_user_pending.load(.seq_cst)) {
                    self.ask_user_pending.store(false, .seq_cst);
                    self.beginPendingReply();
                    if (self.pending_reply) |slot| self.allocator.free(slot);
                    self.pending_reply = null;
                    self.endPendingReply();
                    if (!self.thinking.stopping) {
                        self.hint.left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit";
                    }
                }
                ctx.consumeAndRedraw();
                return;
            }

            // History scrollback.
            //   PageUp / Ctrl-U   — scroll up one page
            //   PageDown / Ctrl-D — scroll down one page
            //   Home / Ctrl-Home  — jump to the top of history
            //   End  / Ctrl-G     — snap back to the live tail
            //
            // The History widget clamps `scroll_offset` against the
            // total wrapped row count, so a wildly-large value here
            // still settles on the first row of the buffer; we use
            // `maxInt(u32)` as a "go all the way up" sentinel rather
            // than computing the exact bound (which would require
            // knowing the pane width here).
            const page_step: u32 = 16;
            if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) {
                self.scroll_offset +|= page_step;
                ctx.redraw = true;
                return;
            }
            if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) {
                self.scroll_offset -|= page_step;
                ctx.redraw = true;
                return;
            }
            if (key.matches(vaxis.Key.home, .{}) or key.matches(vaxis.Key.home, .{ .ctrl = true })) {
                self.scroll_offset = std.math.maxInt(u32);
                ctx.redraw = true;
                return;
            }
            if (key.matches(vaxis.Key.end, .{}) or key.matches('g', .{ .ctrl = true })) {
                self.scroll_offset = 0;
                ctx.redraw = true;
                return;
            }

            // Ctrl-B: toggle expand/collapse on every tool row in
            // history. Tool output is collapsed by default to keep
            // the chat readable; this lets the user see full
            // results without retyping the prompt. Idempotent —
            // pressing it again restores the collapsed view.
            if (key.matches('b', .{ .ctrl = true })) {
                _ = toggleAllToolExpand(self) catch return;
                ctx.consumeAndRedraw();
                return;
            }

            // Slash-menu navigation: when the input buffer starts
            // with `/`, intercept ↑/↓/Esc before they reach the
            // input widget so the popup feels like a real menu.
            const menu_open = self.input.buf.items.len > 0 and self.input.buf.items[0] == '/';
            if (menu_open) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.input.buf.clearRetainingCapacity();
                    self.input.cursor = 0;
                    self.command_menu_cursor = 0;
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.up, .{})) {
                    if (self.command_menu_cursor > 0) self.command_menu_cursor -= 1;
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.command_menu_cursor +|= 1;
                    ctx.consumeAndRedraw();
                    return;
                }
            }

            // Everything else is forwarded to the input widget's
            // handler. vxfw's focus system would do this
            // automatically once we call `request_focus` — we're
            // manually bridging for now since Root is the only
            // widget receiving events.
            const was_pending = self.thinking.pending;
            try self.input.widget().handleEvent(ctx, event);
            // Slash command requested shutdown: honour it on the
            // Root's pass since onSubmit can't reach ctx.quit.
            if (self.quit_requested) {
                ctx.quit = true;
                self.quit_requested = false;
                return;
            }
            // Reset menu cursor when the buffer no longer starts
            // with `/` so the next time it does, we land on top.
            if (self.input.buf.items.len == 0 or self.input.buf.items[0] != '/') {
                self.command_menu_cursor = 0;
            }
            // If onSubmit just flipped a turn to pending, kick the
            // spinner tick chain via ctx.tick (cmd list / timers) —
            // we can't postEvent into the loop here because App.run
            // holds the queue mutex while draining.
            if (!was_pending and self.thinking.pending) {
                try ctx.tick(0, self.widget());
            }
        },
        .mouse => |m| {
            // Touchpad / wheel scrollback. Wheel events fire on
            // `press`; release fires too but we only need one. Step
            // size is intentionally smaller than PageUp's 16 — wheel
            // ticks come fast and a big multiplier gets jumpy.
            const wheel_step: u32 = 3;
            if (m.type == .press) {
                switch (m.button) {
                    .wheel_up => {
                        self.scroll_offset +|= wheel_step;
                        ctx.redraw = true;
                        return;
                    },
                    .wheel_down => {
                        self.scroll_offset -|= wheel_step;
                        ctx.redraw = true;
                        return;
                    },
                    else => {},
                }
            }
        },
        .winsize => ctx.redraw = true,
        .init => {
            // Kick off the spinner tick loop so the header
            // spinner animates while a turn is pending.
            try ctx.tick(80, self.widget());
            // Initial gateway probe so the status bar reads
            // truth at boot. Subsequent probes piggy-back on
            // turn completions — see `ue_done`. Skipped when
            // `io` is null (test mode); the bar then stays
            // `gateway: off` which is the correct default.
            if (self.io) |io| self.setGatewayOn(gateway_probe.probeDefault(io));
            ctx.redraw = true;
        },
        .tick => {
            if (self.thinking.pending) {
                self.thinking.spinner_tick +%= 1;
                self.thinking.elapsed_ms = @intCast(@max(0, vxfw.milliTimestamp() - self.turn_started_ms));
                ctx.redraw = true;
                // Reschedule tick only while a turn is pending.
                try ctx.tick(80, self.widget());
            }
        },
        .app => |ue| try self.handleUserEvent(ctx, ue),
        else => {},
    }
}

/// Drop and free a stale payload. Routed through a per-event-name
/// switch because each payload owns different inner allocations;
/// the leading `epoch: u64` field is what we use to detect stale,
/// but freeing has to be type-aware. Returns `true` if the event was
/// stale and consumed (caller must return); `false` to continue
/// dispatching normally.
fn dropStaleIfNeeded(self: *Root, ue: vxfw.UserEvent) bool {
    // Cast to the concrete payload type first, *then* read epoch.
    // The earlier "peek through a generic header" approach panicked
    // with incorrect-alignment when the heap allocation's actual
    // alignment was looser than `u64`'s 8-byte requirement
    // (different payload types have different leading-field
    // alignment requirements, so `@alignCast` to a one-size-fits-all
    // header was undefined behaviour). Reading via the right type
    // sidesteps that — the allocator stamped the right alignment for
    // *that* type when it created the payload.
    const a = self.allocator;
    const data = ue.data orelse return false;

    if (std.mem.eql(u8, ue.name, ue_chunk)) {
        const p: *ChunkPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.agent);
        a.free(p.text);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_tool_start)) {
        const p: *ToolStartPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.agent);
        a.free(p.id);
        a.free(p.name);
        a.free(p.args_summary);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_tool_progress)) {
        const p: *ToolProgressPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.agent);
        a.free(p.id);
        a.free(p.chunk);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_tool_done)) {
        const p: *ToolDonePayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.agent);
        a.free(p.id);
        a.free(p.name);
        a.free(p.output);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_ask_user)) {
        const p: *AskUserPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.question);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_usage)) {
        const p: *UsagePayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_error)) {
        const p: *ErrorPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.message);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_done)) {
        const p: *DonePayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        if (p.invoker) |s| a.free(s);
        a.free(p.target_agent);
        a.free(p.output);
        a.destroy(p);
    } else if (std.mem.eql(u8, ue.name, ue_subturn_timeout)) {
        const p: *SubturnTimeoutPayload = @ptrCast(@alignCast(@constCast(data)));
        if (p.epoch == self.turn_epoch) return false;
        a.free(p.invoker);
        a.free(p.target);
        a.destroy(p);
    } else {
        // Unknown event with a payload — leak the bytes rather than
        // free through the wrong type. Should not happen in practice.
        return false;
    }
    return true;
}

pub fn handleUserEvent(self: *Root, ctx: *vxfw.EventContext, ue: vxfw.UserEvent) !void {
    if (dropStaleIfNeeded(self, ue)) return;
    if (std.mem.eql(u8, ue.name, ue_chunk)) {
        // Live tail policy: incoming chunks always snap the
        // viewport back to the bottom so the user never types into
        // a session whose latest reply scrolled off-screen.
        self.scroll_offset = 0;

        const p: *const ChunkPayload = @ptrCast(@alignCast(ue.data.?));
        // Defers run LIFO: capture inner slices into locals so we
        // can free them *after* destroying the payload allocation —
        // otherwise the reverse-order destroy runs first, then
        // `free(p.text)` reads a dangling `p`.
        const text_slice = p.text;
        const agent_slice = p.agent;
        defer self.allocator.destroy(@as(*ChunkPayload, @constCast(p)));
        defer self.allocator.free(text_slice);
        defer self.allocator.free(agent_slice);

        // Per-agent pending-line lookup. Each agent has its own
        // open line in the map, so concurrent sub-turn streams
        // append to their own row without alternating with peers.
        // First chunk for an agent (or first chunk after a tool
        // boundary) opens a fresh line at the current tail; later
        // chunks append to it. We don't try to reuse a line that
        // already has tool rows after it — the open-line index is
        // valid only as long as nothing has appended past it.
        const idx = self.getPendingAgentLine(p.agent) orelse blk: {
            dispatch_log.info("ue_chunk: opening new agent line for @{s} (epoch={d})", .{ p.agent, p.epoch });
            try self.appendLineWithSpeaker(.agent, "", p.agent);
            const new_idx = self.history.items.len - 1;
            try self.setPendingAgentLine(p.agent, new_idx);
            break :blk new_idx;
        };
        var line = &self.history.items[idx];
        try line.text.appendSlice(self.allocator, p.text);
        self.pending_saw_text = true;
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_start)) {
        const p: *const ToolStartPayload = @ptrCast(@alignCast(ue.data.?));
        const agent_slice = p.agent;
        const id_slice = p.id;
        const name_slice = p.name;
        const args_slice = p.args_summary;
        defer self.allocator.destroy(@as(*ToolStartPayload, @constCast(p)));
        defer self.allocator.free(agent_slice);
        defer self.allocator.free(id_slice);
        defer self.allocator.free(name_slice);
        defer self.allocator.free(args_slice);

        // Tool call breaks the agent-line accumulator for this
        // agent only. Subsequent chunks from the same agent open a
        // fresh line below the tool entry; chunks from peers (other
        // sub-turns running in parallel) keep streaming into their
        // own pending line untouched.
        self.clearPendingAgentLine(agent_slice);
        if (!self.tool_output_enabled) {
            ctx.redraw = true;
            return;
        }

        // Idempotent on tool_use id: a `tool_start` may fire twice
        // for the same call — once early from the provider on
        // content_block_start (id+name only, args still streaming),
        // once later from the runner before dispatch (id+name+full
        // args_summary). On a repeat, just refresh the args and
        // re-render in place; don't create a duplicate row.
        if (self.history.items.len > 0) {
            var i: usize = self.history.items.len;
            while (i > 0) {
                i -= 1;
                const entry = &self.history.items[i];
                if (entry.role != .tool) continue;
                if (entry.tool_id == null) continue;
                if (!std.mem.eql(u8, entry.tool_id.?, id_slice)) continue;
                // Same id — second start. If this fire carries
                // args (the runner's post-round one does, the
                // provider's early one doesn't), use them.
                if (args_slice.len > 0) {
                    if (entry.tool_args) |old| self.allocator.free(old);
                    entry.tool_args = try self.allocator.dupe(u8, args_slice);
                }
                try renderToolLine(self.allocator, entry);
                ctx.redraw = true;
                return;
            }
        }

        // Pending row: render header without summary or
        // continuation glyph. `turn_tool_done` later swaps in the
        // collapsed `<header>\n  └ <summary>` block.
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        try renderToolHeader(self.allocator, &text, name_slice, args_slice);

        const id_owned = try self.allocator.dupe(u8, p.id);
        errdefer self.allocator.free(id_owned);
        const name_owned = try self.allocator.dupe(u8, p.name);
        errdefer self.allocator.free(name_owned);
        const args_owned = try self.allocator.dupe(u8, p.args_summary);
        errdefer self.allocator.free(args_owned);
        // Stamp the owning agent on the tool row so the renderer
        // can paint the speaker pill alongside the tool limb. In
        // multi-agent dispatch the chain is "@bolt called X" but
        // without a pill on the tool row itself, a glance at the
        // chat reads as if the tool had no owner — especially
        // when a tool fires immediately after the prompt with no
        // preceding text from that agent.
        const speaker_owned = try self.allocator.dupe(u8, p.agent);
        errdefer self.allocator.free(speaker_owned);

        try self.history.append(self.allocator, .{
            .role = .tool,
            .text = text,
            .speaker = speaker_owned,
            .tool_id = id_owned,
            .tool_name = name_owned,
            .tool_args = args_owned,
            .tool_turn_id = self.current_turn_id,
            .tool_started_ms = vxfw.milliTimestamp(),
        });
        // Earlier tool lines from the same turn need to re-render
        // with `├─` instead of `└─` now that a new sibling exists.
        try rerenderTurnTools(self, self.current_turn_id);
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_progress)) {
        const p: *const ToolProgressPayload = @ptrCast(@alignCast(ue.data.?));
        const agent_slice = p.agent;
        const id_slice = p.id;
        const chunk_slice = p.chunk;
        defer self.allocator.destroy(@as(*ToolProgressPayload, @constCast(p)));
        defer self.allocator.free(agent_slice);
        defer self.allocator.free(id_slice);
        defer self.allocator.free(chunk_slice);

        // Find the running tool entry with this id and update its
        // last-line tail. Live progress shows the bottom line of
        // whatever the shell just wrote, dimmed under the tool's
        // header — gives the user a real "git push origin main /
        // counting objects: 42 / done" feel during long commands.
        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.history.items[i];
            if (entry.role != .tool) continue;
            if (entry.tool_id == null) continue;
            if (!std.mem.eql(u8, entry.tool_id.?, id_slice)) continue;

            // Take the last non-empty line of the chunk. Shells
            // emit progress as "\rcounting objects: 42\r" or with
            // bare newlines; we want one stable line, not a tower.
            const tail = lastNonEmptyLine(chunk_slice);
            if (tail.len > 0) {
                if (entry.tool_progress_tail) |old| self.allocator.free(old);
                // Cap at 200 chars so a runaway log line doesn't
                // explode the row.
                const capped = if (tail.len > 200) tail[0..200] else tail;
                entry.tool_progress_tail = try self.allocator.dupe(u8, capped);
                try renderToolLine(self.allocator, entry);
                ctx.redraw = true;
            }
            break;
        }
    } else if (std.mem.eql(u8, ue.name, ue_tool_done)) {
        const p: *const ToolDonePayload = @ptrCast(@alignCast(ue.data.?));
        const agent_slice = p.agent;
        const id_slice = p.id;
        const name_slice = p.name;
        const output_slice = p.output;
        defer self.allocator.destroy(@as(*ToolDonePayload, @constCast(p)));
        defer self.allocator.free(agent_slice);
        defer self.allocator.free(id_slice);
        defer self.allocator.free(name_slice);
        defer self.allocator.free(output_slice);
        // Defensive: tool_start already cleared this agent's
        // pending line. Clear again here in case a tool_done
        // arrives without a prior start (legacy/edge paths).
        self.clearPendingAgentLine(agent_slice);

        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.history.items[i];
            if (entry.role != .tool) continue;
            if (entry.tool_id) |id| {
                if (std.mem.eql(u8, id, p.id)) {
                    // Stash the full output and a summary so the
                    // user can toggle expand/collapse later. Free
                    // the prior args/name only if we somehow got
                    // here without going through ue_tool_start
                    // (defensive — the entry is normally already
                    // populated). Then re-render based on the
                    // current expanded flag.
                    if (entry.tool_summary) |s| self.allocator.free(s);
                    if (entry.tool_full) |s| self.allocator.free(s);
                    entry.tool_summary = try self.allocator.dupe(u8, summarizeToolOutput(p.output));
                    entry.tool_full = try self.allocator.dupe(u8, p.output);
                    entry.tool_status = if (p.is_error) .err else .ok;
                    if (entry.tool_name == null) {
                        entry.tool_name = try self.allocator.dupe(u8, p.name);
                    }
                    if (entry.tool_started_ms != 0) {
                        const elapsed = vxfw.milliTimestamp() - entry.tool_started_ms;
                        entry.tool_duration_ms = if (elapsed < 0) 0 else @intCast(elapsed);
                    }
                    try renderToolLine(self.allocator, entry);
                    entry.deinitToolId(self.allocator);
                    break;
                }
            }
        }
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_ask_user)) {
        const p: *const AskUserPayload = @ptrCast(@alignCast(ue.data.?));
        const q_slice = p.question;
        defer self.allocator.destroy(@as(*AskUserPayload, @constCast(p)));
        defer self.allocator.free(q_slice);

        // Render the question as a system line and arm the
        // pending-reply state so the next submit is captured
        // instead of starting a new turn.
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "? {s}", .{p.question}) catch p.question;
        try self.appendLine(.system, line);
        self.ask_user_pending.store(true, .seq_cst);
        self.hint.left = "type a reply  ·  esc cancels";
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_ask_user_cancel)) {
        // Worker bailed (gate flipped off mid-wait). Clear the
        // pending flag so the next user submit starts a normal
        // turn, drop any orphan reply, and restore the hint.
        self.ask_user_pending.store(false, .seq_cst);
        self.beginPendingReply();
        if (self.pending_reply) |slot| self.allocator.free(slot);
        self.pending_reply = null;
        self.endPendingReply();
        self.hint.left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit";
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_usage)) {
        const p: *const UsagePayload = @ptrCast(@alignCast(ue.data.?));
        defer self.allocator.destroy(@as(*UsagePayload, @constCast(p)));
        if (p.ctx_used > 0) {
            self.status_bar.ctx_used = p.ctx_used;
            ctx.redraw = true;
        }
    } else if (std.mem.eql(u8, ue.name, ue_error)) {
        const p: *const ErrorPayload = @ptrCast(@alignCast(ue.data.?));
        const message_slice = p.message;
        defer self.allocator.destroy(@as(*ErrorPayload, @constCast(p)));
        defer self.allocator.free(message_slice);

        var buf: [256]u8 = undefined;
        const cancelled = std.mem.eql(u8, p.message, "turn cancelled") or
            std.mem.eql(u8, p.message, "Interrupted") or
            std.mem.eql(u8, p.message, "Cancelled");
        const line = if (cancelled)
            "∙ turn cancelled"
        else
            std.fmt.bufPrint(&buf, "! turn failed: {s}", .{p.message}) catch "! turn failed";
        try self.appendLine(.system, line);
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_done)) {
        // Stale completions were already dropped by `dropStaleIfNeeded`
        // above, so reaching here means the epoch matched.
        const data = ue.data orelse return;
        const p: *const DonePayload = @ptrCast(@alignCast(data));
        // Defer the free so we can inspect fields below first.
        defer {
            if (p.invoker) |s| self.allocator.free(s);
            self.allocator.free(p.target_agent);
            self.allocator.free(p.output);
            self.allocator.destroy(@as(*DonePayload, @constCast(p)));
        }

        // Branch on dispatch kind. Sub-turn completions slot in
        // their reply and may trigger a join; primary/resume turns
        // scan their output for fresh mentions and may fan out.
        switch (p.dispatch_kind) {
            .subturn => self.onSubturnDone(p) catch {},
            .primary, .resume_ => self.scanAndFanOut(p) catch {},
        }
        // Re-parse every agent line we accumulated this turn as
        // markdown, swapping the raw text + null spans for the
        // walker's flat text + style spans. The history widget
        // already paints under spans when present; we just need to
        // populate them. Streaming chunks land in raw form; the
        // re-parse only runs once the turn is complete so the model
        // sees consistent partials and the user sees a styled
        // final.
        renderAgentMarkdown(self) catch {};
        markLastToolInTurn(self, self.current_turn_id) catch {};
        // Refresh gateway status. A daemon may have come up or
        // gone down between turns; re-probe cheaply so the bar
        // doesn't lie. The probe is a single TCP connect with a
        // tight timeout — negligible overhead.
        if (self.io) |io| self.setGatewayOn(gateway_probe.probeDefault(io));

        // No placeholder to drop — the chunk handler creates the
        // agent line lazily, so an empty turn leaves no empty
        // line behind. Clear only THIS agent's pending entry;
        // peers running parallel sub-turns keep their own open
        // lines until their own `ue_done` lands.
        self.clearPendingAgentLine(p.target_agent);
        self.pending_saw_text = false;
        self.thinking.pending = false;
        self.thinking.stopping = false;
        self.status_bar.turn_stopping = false;
        self.turn_started_ms = 0;
        self.hint.left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit";
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_subturn_timeout)) {
        const data = ue.data orelse return;
        const p: *const SubturnTimeoutPayload = @ptrCast(@alignCast(data));
        defer {
            self.allocator.free(p.invoker);
            self.allocator.free(p.target);
            self.allocator.destroy(@as(*SubturnTimeoutPayload, @constCast(p)));
        }

        // Mark the slot timed-out only if it's still in_flight —
        // a fast worker may have already posted ue_done. The
        // resume step (commit 6) will treat `timed_out` slots as
        // synthetic-error replies.
        const slot = self.findSubturnSlot(p.invoker, p.target, p.mention_idx) orelse return;
        slot.state = .timed_out;
        slot.error_reason = "timeout";
        if (self.pending_subturns > 0) self.pending_subturns -= 1;

        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "! @{s} timed out (no reply within {d}s)",
            .{ p.target, self.auto_dispatch_subturn_timeout_secs },
        ) catch "! subturn timed out";
        self.appendLine(.system, line) catch {};

        // Timeout decremented `pending_subturns`; if this was the
        // last one, the join+resume fires with a synthetic error
        // for the timed-out slot and any successful replies for the
        // others.
        self.maybeResume() catch {};
        ctx.redraw = true;
    }
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Root = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;

    // Layout (top → bottom):
    //   history                      flex (whatever's left, banner scrolls inside)
    //   thinking                     1 row when pending, else 0
    //   hint                         1 row when texts non-empty, else 0
    //   input panel                  3 rows tinted, text on middle row
    //   status bar                   1 row tinted (workspace · sandbox · model)
    //
    // Bail on degenerate sizes. The footer (input + status_bar)
    // alone needs 4 rows; below that we paint nothing rather than
    // letting the underflow math wrap and corrupt the surface.
    const input_rows: u16 = 3;
    const status_rows: u16 = 1;
    const bottom_pad_rows: u16 = 1;
    const footer_min: u16 = input_rows + status_rows + bottom_pad_rows;

    if (width == 0 or height < footer_min) {
        return try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
        );
    }

    const thinking_rows: u16 = if (self.thinking.pending) 1 else 0;
    const hint_rows: u16 = if (self.hint.left.len > 0 or self.hint.right.len > 0) 1 else 0;

    // Slash-command popup. Visible whenever the input buffer
    // starts with `/`. Items computed once per frame from the
    // arena so we don't allocate on the heap from drawFn.
    const menu_query: []const u8 = if (self.input.buf.items.len > 0 and self.input.buf.items[0] == '/')
        self.input.buf.items[1..]
    else
        "";
    const menu_visible: bool = self.input.buf.items.len > 0 and self.input.buf.items[0] == '/';
    const menu_items: []const CommandMenu.Item = if (menu_visible)
        try CommandMenu.filter(ctx.arena, menu_query)
    else
        &.{};
    const menu_cursor: usize = if (menu_items.len == 0) 0 else @min(self.command_menu_cursor, menu_items.len - 1);
    var menu = CommandMenu{
        .visible_items = menu_items,
        .selected = menu_cursor,
    };
    const menu_rows: u16 = menu.rows();

    // The menu renders below the status bar. When visible, it
    // takes its own rows; the 1-row bottom pad is preserved
    // beneath it so the popup never sits flush with the screen
    // edge.
    const trailing_rows: u16 = if (menu_rows > 0) menu_rows + bottom_pad_rows else bottom_pad_rows;

    // The wordmark banner used to live in a pinned `Header` widget
    // above the chat. It now scrolls with history as `.banner` rows
    // injected once at startup, so the only top-stack row is the
    // chat surface itself.
    const bottom_stack: u16 = thinking_rows + hint_rows + input_rows + status_rows + trailing_rows;
    const history_rows: u16 = if (height > bottom_stack) height - bottom_stack else 0;

    const children = try ctx.arena.alloc(vxfw.SubSurface, 6);
    const surface = try vxfw.Surface.initWithChildren(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
        children,
    );

    var cur_row: u16 = 0;

    // History at full width. Earlier we kept a 1-cell side margin
    // for visual breathing room, but that left a tiny untinted
    // gutter on user-message tints (which span their child surface
    // edge to edge). Going flush keeps the user-message half-block
    // band lined up vertically with the input panel below.
    {
        const view: History = .{
            .lines = self.history.items,
            .scroll_offset = self.scroll_offset,
            .cache = &self.history_cache,
        };
        const s = try view.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = history_rows },
        ));
        surface.children[0] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += history_rows;
    }

    // Thinking row — collapses to 0 when not pending.
    {
        const s = try self.thinking.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = thinking_rows },
        ));
        surface.children[1] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += thinking_rows;
    }

    // Hint row.
    {
        const s = try self.hint.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = hint_rows },
        ));
        surface.children[2] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += hint_rows;
    }

    // Input panel spans full width, edge to edge. The visual
    // breathing room on the sides comes from the terminal window's
    // own padding, not from an explicit widget inset.
    {
        const s = try self.input.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = input_rows },
        ));
        surface.children[3] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += input_rows;
    }

    // Status bar sits above the trailing rows (slash menu when
    // open, otherwise just the bottom pad). Pinned by absolute
    // row so a stray off-by-one earlier in the stack can't hide
    // the footer.
    const status_origin: u16 = height - trailing_rows - status_rows;
    self.status_bar.dispatch_used = self.auto_dispatch_calls;
    self.status_bar.dispatch_max = self.auto_dispatch_max_calls;
    // Live agentic trackers: how many peer subturns are still in
    // flight, and how many bytes of peer chatter are buffered for
    // the next user submit. Both are silently-mutating state that
    // we'd rather have visible at a glance than hidden behind a
    // log line. Cap to u8/u32 — the counters never legitimately
    // get that big.
    self.status_bar.peers_active = blk: {
        const n = self.pending_subturns;
        break :blk if (n > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(n);
    };
    self.status_bar.chatter_bytes = blk: {
        const len = if (self.peer_chatter) |s| s.len else 0;
        break :blk if (len > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(len);
    };
    {
        const s = try self.status_bar.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = status_rows },
        ));
        surface.children[4] = .{ .origin = .{ .row = status_origin, .col = 0 }, .surface = s, .z_index = 0 };
    }

    // Slash-command popup below the status bar. When the menu is
    // hidden, it draws as a zero-height surface and the bottom
    // pad fills the gap.
    {
        const s = try menu.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = menu_rows },
        ));
        surface.children[5] = .{ .origin = .{ .row = status_origin + status_rows, .col = 0 }, .surface = s, .z_index = 0 };
    }

    return surface;
}

/// Walk recent agent lines and re-render their text as markdown.
/// Spans-bearing lines are skipped (already processed). Failures are
/// silent: the line keeps its raw text and renders unstyled, which is
/// strictly less helpful but never wrong.
fn renderAgentMarkdown(self: *Root) !void {
    // Walk back through the current turn re-rendering every agent
    // line we find. A turn can contain multiple agent prose blocks
    // separated by tool rows (the model talks → calls a tool →
    // talks more → calls another tool → ...); each prose block
    // streams in raw and needs the markdown pass on ue_done.
    // Stop at the first user line — that's the previous turn's
    // boundary, and lines above it already had markdown baked in
    // by an earlier ue_done.
    var i: usize = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const line = &self.history.items[i];
        if (line.role == .user) break;
        if (line.role != .agent) continue;
        if (line.spans != null) continue;
        if (line.text.items.len == 0) continue;

        var rendered = md.render(self.allocator, line.text.items) catch continue;
        // Tolerate the parser returning empty text for non-empty
        // input: keep the raw bytes, drop the empty spans slice. The
        // user still sees their reply just without styling.
        if (rendered.text.len == 0) {
            rendered.deinit(self.allocator);
            continue;
        }
        line.text.clearRetainingCapacity();
        line.text.appendSlice(self.allocator, rendered.text) catch {
            rendered.deinit(self.allocator);
            continue;
        };
        line.deinitSpans(self.allocator);
        line.spans = rendered.spans;
        // We took ownership of `spans`; only the text slice is ours
        // to free here.
        self.allocator.free(rendered.text);
    }
}

// --- Tool row rendering ----------------------------------------------------
//
// Tool rows render in three states. Pending: just the header, no
// continuation glyph. Collapsed (default after done): header plus
// one `└ <summary>` line. Expanded (Ctrl-B): header plus full
// output, each line prefixed with the continuation glyph so the
// block reads as one structured unit. Re-renders go through
// `renderToolLine` so toggling expand/collapse paints from the
// stored `tool_full` slice without losing data.

const tool_summary_max_chars: usize = 80;
const tool_args_max_chars: usize = 60;

/// Append the row header `Tool(args)` to `text`. Used by the
/// pending state and as the first line of the done state.
fn renderToolHeader(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    name: []const u8,
    args_summary: []const u8,
) !void {
    // Cosmetic: `use_skill` is the wire name the model sees; the
    // user wants to read it as "Skill(code-review)" in the chat.
    const display_name: []const u8 = if (std.mem.eql(u8, name, "use_skill")) "Skill" else name;
    try text.appendSlice(allocator, display_name);
    if (args_summary.len > 0) {
        try text.append(allocator, '(');
        if (args_summary.len <= tool_args_max_chars) {
            try text.appendSlice(allocator, args_summary);
        } else {
            try text.appendSlice(allocator, args_summary[0..tool_args_max_chars]);
            try text.appendSlice(allocator, "\u{2026}");
        }
        try text.append(allocator, ')');
    }
}

/// One-line preview drawn from the tool's output. First non-empty
/// line, trimmed and capped. Falls back to a "(no output)" marker
/// when the tool wrote nothing.
fn summarizeToolOutput(output: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line.len <= tool_summary_max_chars) return line;
        return line[0..tool_summary_max_chars];
    }
    return "(no output)";
}

/// Return the last non-empty line in `bytes`, trimmed of whitespace
/// and CR. Used by the live tool-progress sink to surface the most
/// recent shell-output line under a running bash row.
///
/// Splits on both '\n' and '\r' so progress bars that overwrite via
/// CR (e.g. `git push` "Counting objects: 42%\r") show their newest
/// state instead of the start-of-line.
fn lastNonEmptyLine(bytes: []const u8) []const u8 {
    var best: []const u8 = "";
    var iter = std.mem.splitAny(u8, bytes, "\r\n");
    while (iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len > 0) best = line;
    }
    return best;
}

/// (Re)render `entry.text` from the tool's structured fields.
/// Idempotent — call after every state change (done lands,
/// expand toggles, args update from a coalesced retry).
fn renderToolLine(allocator: std.mem.Allocator, entry: *tui.Line) !void {
    const name = entry.tool_name orelse return;
    entry.text.clearRetainingCapacity();
    entry.deinitSpans(allocator);
    try renderToolHeader(allocator, &entry.text, name, entry.tool_args orelse "");

    // Indent for continuation rows: 3 cols to clear the limb +
    // bullet (`├─ ● ` is 5 cols but we only paint under the
    // bullet; the limb scaffolding flows from the parent into
    // the next sibling, not down into this row's body).
    const child_indent = "   \u{2514}\u{2500} ";

    const has_full = if (entry.tool_full) |f| f.len > 0 else false;
    if (!has_full) {
        // While the tool is still running we have no `tool_full`
        // yet, but `tool_progress_tail` carries the most-recent
        // shell-output line. Render it under the header so a long
        // command (git push, cargo build) shows live signs of life
        // instead of a frozen "working…".
        if (entry.tool_progress_tail) |tail| {
            if (tail.len > 0) {
                try entry.text.append(allocator, '\n');
                try entry.text.appendSlice(allocator, child_indent);
                try entry.text.appendSlice(allocator, tail);
            }
        }
        return;
    }

    if (entry.tool_expanded) {
        // Expanded: every output line gets the same continuation
        // glyph, so the body reads as a sibling list under the
        // tool header. Duration is shown as the last child below.
        const trimmed = std.mem.trimEnd(u8, entry.tool_full.?, "\n");
        if (trimmed.len > 0) {
            var iter = std.mem.splitScalar(u8, trimmed, '\n');
            while (iter.next()) |body_line| {
                try entry.text.append(allocator, '\n');
                try entry.text.appendSlice(allocator, child_indent);
                try entry.text.appendSlice(allocator, body_line);
            }
        }
    } else if (entry.tool_summary) |s| {
        // Collapsed: one summary line, the most recent output's
        // first non-empty row. The duration sits beneath the
        // summary so the eye can read result→timing top-to-bottom.
        if (s.len > 0) {
            try entry.text.append(allocator, '\n');
            try entry.text.appendSlice(allocator, child_indent);
            try entry.text.appendSlice(allocator, s);
        }
    }

    // Duration row trails the body in both states. Skipped when
    // the dispatch hasn't reported a duration yet (still running
    // or never finished).
    if (entry.tool_duration_ms > 0) {
        var dbuf: [48]u8 = undefined;
        const verb: []const u8 = switch (entry.tool_status) {
            .running => "Running",
            .ok => "Completed",
            .err => "Failed",
        };
        const dur = formatDuration(&dbuf, entry.tool_duration_ms, verb) catch "";
        if (dur.len > 0) {
            try entry.text.append(allocator, '\n');
            try entry.text.appendSlice(allocator, child_indent);
            try entry.text.appendSlice(allocator, dur);
        }
    }

    // Diff coloring: when expanded and the body looks like a
    // unified diff, attach per-line spans so add/remove/hunk rows
    // paint in green/red/amber. The detector keys off the raw
    // body (`tool_full`); spans index into the rendered text by
    // walking it line by line and skipping the `child_indent`
    // prefix on each row.
    if (entry.tool_expanded) {
        if (entry.tool_full) |body| {
            if (looksLikeDiff(body)) {
                entry.spans = try buildDiffSpansForRendered(allocator, entry.text.items, child_indent);
            }
        }
    }
}

/// Walk rendered tool-line text and emit a span per indented diff
/// line. Spans cover the body bytes only (skipping the limb +
/// indent prefix) so the painter colors just the diff content.
fn buildDiffSpansForRendered(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    indent: []const u8,
) ![]md.Span {
    var spans: std.ArrayList(md.Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < rendered.len) {
        const line_start = i;
        while (i < rendered.len and rendered[i] != '\n') i += 1;
        const line_end = i;

        // Only color rows that are body continuations — i.e. lines
        // starting with our indent prefix. Skips the header row
        // and any non-indented duration row.
        if (line_end > line_start and std.mem.startsWith(u8, rendered[line_start..line_end], indent)) {
            const content_start = line_start + indent.len;
            if (content_start < line_end) {
                const c = rendered[content_start];
                const kind: ?md.StyleKind = switch (c) {
                    '+' => .diff_add,
                    '-' => .diff_del,
                    '@' => if (line_end - content_start >= 2 and rendered[content_start + 1] == '@') @as(md.StyleKind, .diff_hunk) else null,
                    else => null,
                };
                if (kind) |k| {
                    try spans.append(allocator, .{
                        .start = @intCast(content_start),
                        .len = @intCast(line_end - content_start),
                        .style = k,
                    });
                }
            }
        }

        if (i < rendered.len) i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

/// True when `text` looks like a unified diff: at least one `@@ `
/// hunk header AND at least one line starting with `+` or `-`
/// that isn't part of `+++`/`---` file headers (those count too
/// — but the hunk marker is the cheap discriminator).
fn looksLikeDiff(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "\n@@ ") == null and !std.mem.startsWith(u8, text, "@@ ")) return false;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '+' or line[0] == '-') return true;
    }
    return false;
}

/// `1234ms` → `Completed in 1.2s`. Sub-second stays as ms; over
/// 60s rolls to `1m 23s`. Caller owns the slice — buffer-backed.
fn formatDuration(buf: []u8, ms: u64, verb: []const u8) ![]const u8 {
    if (ms < 1000) {
        return std.fmt.bufPrint(buf, "{s} in {d}ms", .{ verb, ms });
    }
    if (ms < 60_000) {
        const s = @as(f64, @floatFromInt(ms)) / 1000.0;
        return std.fmt.bufPrint(buf, "{s} in {d:.1}s", .{ verb, s });
    }
    const mins = ms / 60_000;
    const rem_s = (ms % 60_000) / 1000;
    return std.fmt.bufPrint(buf, "{s} in {d}m {d}s", .{ verb, mins, rem_s });
}

/// Re-render every tool row of `turn_id` so the limb glyph
/// reflects the current sibling layout (`├─` mid, `└─` last).
/// Called when a new tool joins a turn or when the turn finishes.
fn rerenderTurnTools(self: *Root, turn_id: u32) !void {
    if (turn_id == 0) return;
    var i: usize = 0;
    while (i < self.history.items.len) : (i += 1) {
        const entry = &self.history.items[i];
        if (entry.role != .tool) continue;
        if (entry.tool_name == null) continue;
        if (entry.tool_turn_id != turn_id) continue;
        try renderToolLine(self.allocator, entry);
    }
}

/// Walk the history once to find the last tool row of `turn_id`,
/// flag it `is_last_in_turn`, and re-render every tool of that
/// turn so limbs render as a clean `├─…├─…└─` chain.
fn markLastToolInTurn(self: *Root, turn_id: u32) !void {
    if (turn_id == 0) return;
    var last_idx: ?usize = null;
    var i: usize = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const entry = &self.history.items[i];
        if (entry.role != .tool) continue;
        if (entry.tool_name == null) continue;
        if (entry.tool_turn_id != turn_id) continue;
        last_idx = i;
        break;
    }
    if (last_idx) |idx| {
        self.history.items[idx].tool_is_last_in_turn = true;
        try rerenderTurnTools(self, turn_id);
    }
}

/// Toggle expand state on every tool row in the history. Called
/// from the Ctrl-B handler. Returns the number of rows touched
/// so the handler can decide whether to bother redrawing.
pub fn toggleAllToolExpand(self: *Root) !usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < self.history.items.len) : (i += 1) {
        const entry = &self.history.items[i];
        if (entry.role != .tool) continue;
        if (entry.tool_name == null) continue;
        entry.tool_expanded = !entry.tool_expanded;
        try renderToolLine(self.allocator, entry);
        n += 1;
    }
    return n;
}

const testing = std.testing;

test "root: tool output defaults on" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    try testing.expect(root.tool_output_enabled);
}

test "subturnFrame: includes invoker name twice and the verbatim reply" {
    const body = try subturnFrame(testing.allocator, "tiger", "let's ask sage");
    defer testing.allocator.free(body);
    // Both the address and the imperative reference the invoker.
    try testing.expect(std.mem.indexOf(u8, body, "@tiger mentioned you") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Respond to tiger") != null);
    // Reply is appended verbatim after the separator.
    try testing.expect(std.mem.indexOf(u8, body, "---\nlet's ask sage") != null);
}

test "subturnFrame: empty reply still produces a well-formed frame" {
    const body = try subturnFrame(testing.allocator, "tiger", "");
    defer testing.allocator.free(body);
    // Must end with the separator + empty body — no trailing junk.
    try testing.expect(std.mem.endsWith(u8, body, "---\n"));
}

test "appendSubturnMarker: writes the chain line as a system row" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();

    try root.appendSubturnMarker("tiger", "sage");
    try testing.expectEqual(@as(usize, 1), root.history.items.len);
    const line = root.history.items[0];
    try testing.expectEqual(tui.Line.Role.system, line.role);
    try testing.expect(std.mem.indexOf(u8, line.text.items, "@tiger") != null);
    try testing.expect(std.mem.indexOf(u8, line.text.items, "@sage") != null);
}

test "buildResumeBody: two done slots in mention order" {
    var slots = [_]SubturnSlot{
        .{
            .target = try testing.allocator.dupe(u8, "sage"),
            .mention_idx = 0,
            .state = .done,
            .reply = try testing.allocator.dupe(u8, "sage's take"),
        },
        .{
            .target = try testing.allocator.dupe(u8, "bolt"),
            .mention_idx = 1,
            .state = .done,
            .reply = try testing.allocator.dupe(u8, "bolt's take"),
        },
    };
    defer for (&slots) |*s| s.deinit(testing.allocator);

    const body = try buildResumeBody(testing.allocator, &slots);
    defer testing.allocator.free(body);
    const expected =
        "@sage replied:\nsage's take\n\n" ++
        "@bolt replied:\nbolt's take";
    try testing.expectEqualStrings(expected, body);
}

test "buildResumeBody: timed-out slot becomes synthetic error line" {
    var slots = [_]SubturnSlot{
        .{
            .target = try testing.allocator.dupe(u8, "sage"),
            .mention_idx = 0,
            .state = .done,
            .reply = try testing.allocator.dupe(u8, "ok"),
        },
        .{
            .target = try testing.allocator.dupe(u8, "bolt"),
            .mention_idx = 1,
            .state = .timed_out,
            .error_reason = "timeout",
        },
    };
    defer for (&slots) |*s| s.deinit(testing.allocator);

    const body = try buildResumeBody(testing.allocator, &slots);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "@sage replied:\nok") != null);
    try testing.expect(std.mem.indexOf(u8, body, "@bolt replied:\nError: @bolt did not respond (timeout)") != null);
}

test "buildResumeBody: empty slot list yields empty body" {
    const slots = [_]SubturnSlot{};
    const body = try buildResumeBody(testing.allocator, &slots);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
}

test "scanAndFanOut: empty output leaves state untouched" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();
    const known = [_][]const u8{ "tiger", "sage" };
    root.agent_names = &known;

    const p: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .primary,
        .invoker = null,
        .target_agent = try testing.allocator.dupe(u8, "tiger"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, ""),
    };
    defer testing.allocator.free(p.target_agent);
    defer testing.allocator.free(p.output);

    try root.scanAndFanOut(&p);
    try testing.expectEqual(@as(usize, 0), root.subturn_slots.items.len);
    try testing.expectEqual(@as(usize, 0), root.pending_subturns);
    try testing.expect(root.invoker_to_resume == null);
}

test "e2e: tiger fans out to @sage @bolt, joins replies, resumes invoker" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();
    const known = [_][]const u8{ "tiger", "sage", "bolt" };
    root.agent_names = &known;

    // Step 1: tiger's primary turn finishes with a reply mentioning
    // both other agents. `scanAndFanOut` records two slots and sets
    // `invoker_to_resume`.
    const tiger_done: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .primary,
        .invoker = null,
        .target_agent = try testing.allocator.dupe(u8, "tiger"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, "let me ask @sage and @bolt"),
    };
    defer testing.allocator.free(tiger_done.target_agent);
    defer testing.allocator.free(tiger_done.output);

    try root.scanAndFanOut(&tiger_done);
    try testing.expectEqual(@as(usize, 2), root.subturn_slots.items.len);
    try testing.expectEqual(@as(usize, 2), root.pending_subturns);
    try testing.expectEqualStrings("tiger", root.invoker_to_resume.?);
    // Two model calls reserved (one per sub-turn dispatch).
    try testing.expectEqual(@as(u8, 2), root.auto_dispatch_calls);

    // Step 2: sage replies. `pending_subturns` decrements; resume
    // not yet (bolt still in flight).
    const sage_done: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .subturn,
        .invoker = try testing.allocator.dupe(u8, "tiger"),
        .target_agent = try testing.allocator.dupe(u8, "sage"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, "sage's view"),
    };
    defer testing.allocator.free(sage_done.invoker.?);
    defer testing.allocator.free(sage_done.target_agent);
    defer testing.allocator.free(sage_done.output);
    try root.onSubturnDone(&sage_done);
    try testing.expectEqual(@as(usize, 1), root.pending_subturns);
    try testing.expect(root.last_resume_body == null);

    // Step 3: bolt replies. Last sub-turn → join + resume fires.
    const bolt_done: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .subturn,
        .invoker = try testing.allocator.dupe(u8, "tiger"),
        .target_agent = try testing.allocator.dupe(u8, "bolt"),
        .mention_idx = 1,
        .output = try testing.allocator.dupe(u8, "bolt's view"),
    };
    defer testing.allocator.free(bolt_done.invoker.?);
    defer testing.allocator.free(bolt_done.target_agent);
    defer testing.allocator.free(bolt_done.output);
    try root.onSubturnDone(&bolt_done);

    // After the last sub-turn lands, fan-out state is drained but
    // no resume fires — sub-turn replies are the agents' contributions
    // to the chat, full stop. Tiger does not get a synthesizing
    // follow-up turn.
    try testing.expectEqual(@as(usize, 0), root.subturn_slots.items.len);
    try testing.expectEqual(@as(usize, 0), root.pending_subturns);
    try testing.expect(root.invoker_to_resume == null);
    try testing.expect(root.last_resume_body == null);
    // Only the two sub-turn dispatches were counted; no resume call.
    try testing.expectEqual(@as(u8, 2), root.auto_dispatch_calls);
}

test "scanAndFanOut: budget halt skips dispatch when reserve exhausted" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();
    const known = [_][]const u8{ "tiger", "sage", "bolt" };
    root.agent_names = &known;

    // Set budget so the resume reserve already exhausts it (used+1 >= cap).
    // With cap=1 and used=0: used+1 == cap → halt with zero dispatched.
    root.auto_dispatch_max_calls = 1;
    root.auto_dispatch_calls = 0;

    const p: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .primary,
        .invoker = null,
        .target_agent = try testing.allocator.dupe(u8, "tiger"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, "ping @sage @bolt"),
    };
    defer testing.allocator.free(p.target_agent);
    defer testing.allocator.free(p.output);

    try root.scanAndFanOut(&p);
    try testing.expectEqual(@as(usize, 0), root.subturn_slots.items.len);
    try testing.expectEqual(@as(usize, 0), root.pending_subturns);

    // A halt system row must have been emitted listing both skipped names.
    try testing.expect(root.history.items.len >= 1);
    const last = root.history.items[root.history.items.len - 1];
    try testing.expectEqual(tui.Line.Role.system, last.role);
    try testing.expect(std.mem.indexOf(u8, last.text.items, "@sage") != null);
    try testing.expect(std.mem.indexOf(u8, last.text.items, "@bolt") != null);
    try testing.expect(std.mem.indexOf(u8, last.text.items, "budget reached") != null);
}

test "scanAndFanOut: no agent_names → no fan-out attempted" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();
    // agent_names left as default empty slice.

    const p: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .primary,
        .invoker = null,
        .target_agent = try testing.allocator.dupe(u8, "tiger"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, "ping @sage @bolt"),
    };
    defer testing.allocator.free(p.target_agent);
    defer testing.allocator.free(p.output);

    try root.scanAndFanOut(&p);
    try testing.expectEqual(@as(usize, 0), root.subturn_slots.items.len);
}

test "onSubturnDone: marks slot done and decrements pending_subturns" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();

    // Seed two slots so `pending_subturns` decrements to 1 — that
    // keeps `maybeResume` from firing, leaving the just-completed
    // slot inspectable. End-to-end resume behavior is exercised
    // separately via `buildResumeBody` / e2e tests.
    try root.subturn_slots.append(testing.allocator, .{
        .target = try testing.allocator.dupe(u8, "sage"),
        .mention_idx = 0,
        .state = .in_flight,
    });
    try root.subturn_slots.append(testing.allocator, .{
        .target = try testing.allocator.dupe(u8, "bolt"),
        .mention_idx = 1,
        .state = .in_flight,
    });
    root.pending_subturns = 2;
    root.invoker_to_resume = try testing.allocator.dupe(u8, "tiger");

    const p: DonePayload = .{
        .epoch = 0,
        .dispatch_kind = .subturn,
        .invoker = try testing.allocator.dupe(u8, "tiger"),
        .target_agent = try testing.allocator.dupe(u8, "sage"),
        .mention_idx = 0,
        .output = try testing.allocator.dupe(u8, "sage's reply"),
    };
    defer testing.allocator.free(p.invoker.?);
    defer testing.allocator.free(p.target_agent);
    defer testing.allocator.free(p.output);

    try root.onSubturnDone(&p);
    try testing.expectEqual(SubturnSlot.State.done, root.subturn_slots.items[0].state);
    try testing.expectEqualStrings("sage's reply", root.subturn_slots.items[0].reply.?);
    try testing.expectEqual(@as(usize, 1), root.pending_subturns);
}

test "clearSubturnState: drops in-flight slots and resets counters" {
    var root = Root.init(testing.allocator, .{ .agent_name = "tiger" });
    defer root.deinit();

    // Fake an in-flight fan-out: two slots, an invoker, a budget tick.
    try root.subturn_slots.append(testing.allocator, .{
        .target = try testing.allocator.dupe(u8, "sage"),
        .mention_idx = 0,
        .state = .in_flight,
    });
    try root.subturn_slots.append(testing.allocator, .{
        .target = try testing.allocator.dupe(u8, "bolt"),
        .mention_idx = 1,
        .state = .in_flight,
    });
    root.invoker_to_resume = try testing.allocator.dupe(u8, "tiger");
    root.pending_subturns = 2;
    root.auto_dispatch_calls = 2;

    root.clearSubturnState();
    try testing.expectEqual(@as(usize, 0), root.subturn_slots.items.len);
    try testing.expect(root.invoker_to_resume == null);
    try testing.expectEqual(@as(usize, 0), root.pending_subturns);
    try testing.expectEqual(@as(u8, 0), root.auto_dispatch_calls);
}

test "root: /tools without args enables output" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();
    root.tool_output_enabled = false;

    root.dispatchCommand("tools");

    try testing.expect(root.tool_output_enabled);
    try testing.expect(root.history.items.len == 1);
    try testing.expectEqualStrings("tool output: on", root.history.items[0].text.items);
}

test "/stop with no runner: surfaces a system error and returns" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    root.dispatchCommand("stop");

    try testing.expect(root.history.items.len == 1);
    try testing.expectEqualStrings("stop: no runner attached", root.history.items[0].text.items);
}

test "/stop <unknown agent> with runner attached: surfaces unknown-agent error" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    // Wire a mock runner so the no-runner branch doesn't short-circuit.
    var mock = harness.agent_runner.MockAgentRunner.init();
    var runner = mock.runner();
    root.runner = &runner;
    root.agent_names = &[_][]const u8{ "tiger", "sage", "bolt" };

    root.dispatchCommand("stop nobody");

    try testing.expect(root.history.items.len == 1);
    try testing.expectEqualStrings("stop: unknown agent `nobody`", root.history.items[0].text.items);
}

test "appendPeerChatter: small replies accumulate verbatim" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    try root.appendPeerChatter("sage", "first reply");
    try root.appendPeerChatter("bolt", "second reply");

    const buf = root.peer_chatter orelse return error.NoChatter;
    try testing.expect(std.mem.indexOf(u8, buf, "[sage said]\nfirst reply") != null);
    try testing.expect(std.mem.indexOf(u8, buf, "[bolt said]\nsecond reply") != null);
    // Order preserved: sage block precedes bolt block.
    const sage_pos = std.mem.indexOf(u8, buf, "[sage said]").?;
    const bolt_pos = std.mem.indexOf(u8, buf, "[bolt said]").?;
    try testing.expect(sage_pos < bolt_pos);
}

test "appendPeerChatter: oversized single block is truncated to cap" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    const huge = try testing.allocator.alloc(u8, 2 * peer_chatter_cap);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');

    try root.appendPeerChatter("sage", huge);

    const buf = root.peer_chatter orelse return error.NoChatter;
    try testing.expect(buf.len <= peer_chatter_cap);
    try testing.expect(std.mem.endsWith(u8, buf, "[...truncated]"));
}

test "appendPeerChatter: oldest blocks dropped FIFO when cap exceeded" {
    var root = Root.init(testing.allocator, .{});
    defer root.deinit();

    // Fill close to the cap with several distinguishable blocks, then
    // append one more big enough to push out the oldest.
    const block_size: usize = 8 * 1024;
    const payload = try testing.allocator.alloc(u8, block_size);
    defer testing.allocator.free(payload);

    @memset(payload, 'a');
    try root.appendPeerChatter("sage", payload);
    @memset(payload, 'b');
    try root.appendPeerChatter("bolt", payload);
    @memset(payload, 'c');
    try root.appendPeerChatter("tiger", payload);
    @memset(payload, 'd');
    try root.appendPeerChatter("sage", payload);
    @memset(payload, 'e');
    try root.appendPeerChatter("bolt", payload); // pushes total over cap

    const buf = root.peer_chatter orelse return error.NoChatter;
    try testing.expect(buf.len <= peer_chatter_cap);
    // Newest block always preserved.
    try testing.expect(std.mem.indexOf(u8, buf, "eeee") != null);
    // Oldest block (all 'a') was dropped to make room.
    try testing.expect(std.mem.indexOf(u8, buf, "aaaa") == null);
}
