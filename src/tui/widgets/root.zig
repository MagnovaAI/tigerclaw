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
const Header = @import("header.zig");
const History = @import("history.zig");
const Input = @import("input.zig");
const Thinking = @import("thinking.zig");
const Hint = @import("hint.zig");
const StatusBar = @import("status_bar.zig");
const CommandMenu = @import("command_menu.zig");
const skills_mod = @import("../../skills/skills.zig");

const Root = @This();

// --- state ---
allocator: std.mem.Allocator,
header: Header,
/// Heap-allocated chat history. Owned by the Root widget; freed
/// on deinit. Lines are appended by the event handler in
/// response to key presses and runner events. The History
/// widget borrows a slice of this list per frame.
history: std.ArrayList(tui.Line) = .empty,
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
/// Borrowed runner. Set by \`attachRunner\` before \`App.run\`;
/// null during tests that don't spin up a real runner.
runner: ?*harness.AgentRunner = null,
/// Agent session id — normally the agent name. Reused across
/// turns so the context engine keeps continuity.
session_id: []const u8 = "tiger",
/// Borrowed App pointer. Used by worker-thread sinks to post
/// UserEvents back into the main loop via \`app.loop.?.postEvent\`.
app: ?*vxfw.App = null,
/// History index of the line currently being streamed into. Set
/// when a turn starts; reset on done/error.
pending_agent_line: ?usize = null,
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
    io: ?std.Io = null,
};

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) Root {
    return .{
        .allocator = allocator,
        .header = .{
            .agent_name = opts.agent_name,
            .model_line = opts.model_line,
            .workspace = opts.workspace,
        },
        .input = Input.init(allocator),
        .session_id = opts.agent_name,
        .home_dir = opts.home,
        .workspace_dir = opts.workspace,
        .io = opts.io,
        .status_bar = .{
            .workspace = if (opts.workspace.len == 0) "~" else opts.workspace,
            .sandbox = "unlocked",
            .model = opts.model_line,
            .sandbox_caution = false,
        },
    };
}

/// Wire the runner + app so submit actually fires a turn. Call
/// after \`init\` and before \`app.run(root.widget(), .{})\`.
pub fn attachRunner(self: *Root, runner: *harness.AgentRunner, app: *vxfw.App) void {
    self.runner = runner;
    self.app = app;
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
    }
    self.history.deinit(self.allocator);
    self.input.deinit();
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
        self.appendLine(.user, text) catch {};
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

    // Don't start a second turn while one is in flight. The user
    // can type the next message — it'll just queue up as another
    // history line but the runner won't fire.
    if (self.thinking.pending) {
        self.appendLine(.user, text) catch {};
        return;
    }
    self.beginTurn(text) catch |err| {
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
        if (std.mem.eql(u8, args, "on")) {
            self.tool_output_enabled = true;
            self.appendLine(.system, "tool output: on") catch {};
        } else if (std.mem.eql(u8, args, "off")) {
            self.tool_output_enabled = false;
            self.appendLine(.system, "tool output: off") catch {};
        } else {
            const msg = if (self.tool_output_enabled) "tool output: on (use `/tools off` to hide)" else "tool output: off (use `/tools on` to show)";
            self.appendLine(.system, msg) catch {};
        }
        return;
    }
    if (std.mem.eql(u8, name, "config")) {
        self.runConfigCommand() catch {};
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

    self.status_bar.sandbox = switch (mode) {
        .unlocked => "unlocked",
        .locked => "locked",
        .plan => "plan",
    };
    self.status_bar.sandbox_caution = mode != .unlocked;

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
    payload.* = .{ .question = try allocator.dupe(u8, question) };
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
pub const ue_tool_done = "tui.tool_done";
pub const ue_done = "tui.done";
pub const ue_error = "tui.error";
pub const ue_tick = "tui.tick";
pub const ue_ask_user = "tui.ask_user";
pub const ue_ask_user_cancel = "tui.ask_user_cancel";

pub const ChunkPayload = struct { text: []u8 };
pub const AskUserPayload = struct { question: []u8 };
pub const ToolStartPayload = struct { id: []u8, name: []u8, args_summary: []u8 };
pub const ToolDonePayload = struct { id: []u8, name: []u8, output: []u8, is_error: bool };
pub const ErrorPayload = struct { message: []u8 };

/// Context the worker thread carries. Allocated on heap;
/// worker frees on exit.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    app: *vxfw.App,
    message: []u8,
    session_id: []const u8,
};

fn beginTurn(self: *Root, typed: []const u8) !void {
    const runner = self.runner orelse return error.NoRunner;
    const app = self.app orelse return error.NoApp;

    try self.appendLine(.user, typed);
    // Submitting a new turn snaps the viewport back to the live
    // tail. If the user was reviewing scrollback, their fresh
    // message — and its incoming reply — should be visible.
    self.scroll_offset = 0;
    // No pre-reserved agent line. Chunks that arrive before a
    // tool_start get a fresh agent line via the lazy path in
    // the chunk handler; chunks that arrive *after* tool lines
    // get their own agent line below the tools. This keeps the
    // reading order natural — tool calls nest between the
    // user prompt and the agent's final reply.
    self.pending_agent_line = null;
    self.pending_saw_text = false;

    self.thinking.pending = true;
    self.thinking.spinner_tick = 0;
    // Rotate verb per turn via a cheap LCG; anything is fine here
    // since we just want the verb to change each time.
    self.thinking.verb_index = @intCast(@mod(vxfw.milliTimestamp(), 0xFF));
    self.thinking.elapsed_ms = 0;
    self.turn_started_ms = vxfw.milliTimestamp();

    // Note: we do NOT kick the tick chain via `app.loop.postEvent(.tick)`
    // here — App.run holds the queue mutex while iterating drained events,
    // so re-entering postEvent from inside a key_press handler deadlocks
    // on the (non-recursive) pthread mutex. The caller (eventHandler in
    // Root) re-arms the tick chain via `ctx.tick(0, …)` after this returns,
    // which routes through the cmd list / timers and bypasses the queue.

    // Dup the message so the worker owns it independent of the
    // input buffer (which clears right after on_submit returns).
    const message_copy = try self.allocator.dupe(u8, typed);
    errdefer self.allocator.free(message_copy);

    const ctx = try self.allocator.create(WorkerCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .allocator = self.allocator,
        .root = self,
        .app = app,
        .message = message_copy,
        .session_id = self.session_id,
    };
    _ = runner;

    var thread = try std.Thread.spawn(.{}, workerMain, .{ctx});
    thread.detach();
}

fn workerMain(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.message);
        ctx.allocator.destroy(ctx);
    }

    const runner = ctx.root.runner orelse {
        postError(ctx, "no runner");
        postDone(ctx);
        return;
    };

    const result = runner.run(.{
        .session_id = ctx.session_id,
        .input = ctx.message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = @ptrCast(ctx),
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = @ptrCast(ctx),
    }) catch |err| {
        postError(ctx, @errorName(err));
        postDone(ctx);
        return;
    };
    _ = result;
    postDone(ctx);
}

// Runner sinks — run on the worker thread. Each one heap-
// allocates a payload struct, attaches it to a \`UserEvent\`, and
// posts to the main loop. The loop's event handler casts the
// pointer back and frees.

fn chunkSink(sink_ctx: ?*anyopaque, fragment: []const u8) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    const payload = ctx.allocator.create(ChunkPayload) catch return;
    payload.* = .{ .text = ctx.allocator.dupe(u8, fragment) catch {
        ctx.allocator.destroy(payload);
        return;
    } };
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
            payload.* = .{
                .id = ctx.allocator.dupe(u8, s.id) catch {
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, s.name) catch {
                    ctx.allocator.free(payload.id);
                    ctx.allocator.destroy(payload);
                    return;
                },
                // Dupe even when empty so the consumer can free
                // unconditionally without branching on length.
                .args_summary = ctx.allocator.dupe(u8, s.args_summary) catch {
                    ctx.allocator.free(payload.id);
                    ctx.allocator.free(payload.name);
                    ctx.allocator.destroy(payload);
                    return;
                },
            };
            postUserEvent(ctx, ue_tool_start, payload);
        },
        .progress => return,
        .finished => |f| {
            const preview = tool_preview.render(ctx.allocator, f.name, f.kind) catch
                ctx.allocator.dupe(u8, f.kind.flatText()) catch return;
            const payload = ctx.allocator.create(ToolDonePayload) catch {
                ctx.allocator.free(preview);
                return;
            };
            payload.* = .{
                .id = ctx.allocator.dupe(u8, f.id) catch {
                    ctx.allocator.free(preview);
                    ctx.allocator.destroy(payload);
                    return;
                },
                .name = ctx.allocator.dupe(u8, f.name) catch {
                    ctx.allocator.free(preview);
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
    payload.* = .{ .message = ctx.allocator.dupe(u8, message) catch {
        ctx.allocator.destroy(payload);
        return;
    } };
    postUserEvent(ctx, ue_error, payload);
}

fn postDone(ctx: *WorkerCtx) void {
    postUserEvent(ctx, ue_done, null);
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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, text);
    try self.history.append(self.allocator, .{
        .role = role,
        .text = buf,
    });
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
        .key_press => |key| {
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
                self.runner.?.cancel(0);
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
                    self.hint.left = "↑↓ scroll  ·  ctrl-b expand tools  ·  ctrl-c quit";
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

pub fn handleUserEvent(self: *Root, ctx: *vxfw.EventContext, ue: vxfw.UserEvent) !void {
    if (std.mem.eql(u8, ue.name, ue_chunk)) {
        // Live tail policy: incoming chunks always snap the
        // viewport back to the bottom so the user never types into
        // a session whose latest reply scrolled off-screen.
        self.scroll_offset = 0;

        const p: *const ChunkPayload = @ptrCast(@alignCast(ue.data.?));
        // Defers run LIFO: capture `text` into a local so we can
        // free it *after* destroying the payload allocation —
        // otherwise the reverse-order destroy runs first, then
        // `free(p.text)` reads a dangling `p`.
        const text_slice = p.text;
        defer self.allocator.destroy(@as(*ChunkPayload, @constCast(p)));
        defer self.allocator.free(text_slice);

        // Lazily create (or reuse) an agent line at the current
        // end of history. `pending_agent_line` is set on the
        // first chunk and cleared whenever a tool event lands,
        // so chunks before + after tools each live on their own
        // line in the natural reading order.
        const idx = self.pending_agent_line orelse blk: {
            try self.appendLine(.agent, "");
            const new_idx = self.history.items.len - 1;
            self.pending_agent_line = new_idx;
            break :blk new_idx;
        };
        var line = &self.history.items[idx];
        try line.text.appendSlice(self.allocator, p.text);
        self.pending_saw_text = true;
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_start)) {
        const p: *const ToolStartPayload = @ptrCast(@alignCast(ue.data.?));
        const id_slice = p.id;
        const name_slice = p.name;
        const args_slice = p.args_summary;
        defer self.allocator.destroy(@as(*ToolStartPayload, @constCast(p)));
        defer self.allocator.free(id_slice);
        defer self.allocator.free(name_slice);
        defer self.allocator.free(args_slice);

        // Tool call breaks the current agent-line accumulator.
        // Subsequent chunks (post-tool) create a fresh agent
        // line below the tool entry.
        self.pending_agent_line = null;
        if (!self.tool_output_enabled) {
            ctx.redraw = true;
            return;
        }

        // Coalesce consecutive same-tool calls. When the model
        // calls `edit_file` repeatedly while iterating, show a
        // single row whose args swap to whatever the current
        // call is editing (`edit_file(foo.py)` → `edit_file(bar.py)`)
        // instead of stacking five rows. Match by tool name only;
        // the args reflect the most recent call. Status flips
        // back to `.running` so the bullet shows in-flight again.
        if (self.history.items.len > 0) {
            const last = &self.history.items[self.history.items.len - 1];
            if (last.role == .tool and last.tool_name != null and
                std.mem.eql(u8, last.tool_name.?, name_slice))
            {
                last.tool_status = .running;
                if (last.tool_args) |old| self.allocator.free(old);
                last.tool_args = try self.allocator.dupe(u8, args_slice);
                if (last.tool_id) |old| self.allocator.free(old);
                last.tool_id = try self.allocator.dupe(u8, id_slice);
                // Drop the prior call's full output and summary —
                // the row now represents the new call. Ctrl-B
                // expand will show the new call's body when it
                // lands.
                if (last.tool_summary) |s| self.allocator.free(s);
                if (last.tool_full) |s| self.allocator.free(s);
                last.tool_summary = null;
                last.tool_full = null;
                try renderToolLine(self.allocator, last);
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

        try self.history.append(self.allocator, .{
            .role = .tool,
            .text = text,
            .tool_id = id_owned,
            .tool_name = name_owned,
            .tool_args = args_owned,
        });
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_tool_done)) {
        const p: *const ToolDonePayload = @ptrCast(@alignCast(ue.data.?));
        const id_slice = p.id;
        const name_slice = p.name;
        const output_slice = p.output;
        defer self.allocator.destroy(@as(*ToolDonePayload, @constCast(p)));
        defer self.allocator.free(id_slice);
        defer self.allocator.free(name_slice);
        defer self.allocator.free(output_slice);

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
    } else if (std.mem.eql(u8, ue.name, ue_error)) {
        const p: *const ErrorPayload = @ptrCast(@alignCast(ue.data.?));
        const message_slice = p.message;
        defer self.allocator.destroy(@as(*ErrorPayload, @constCast(p)));
        defer self.allocator.free(message_slice);

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "! turn failed: {s}", .{p.message}) catch "! turn failed";
        try self.appendLine(.system, line);
        ctx.redraw = true;
    } else if (std.mem.eql(u8, ue.name, ue_done)) {
        // Re-parse every agent line we accumulated this turn as
        // markdown, swapping the raw text + null spans for the
        // walker's flat text + style spans. The history widget
        // already paints under spans when present; we just need to
        // populate them. Streaming chunks land in raw form; the
        // re-parse only runs once the turn is complete so the model
        // sees consistent partials and the user sees a styled
        // final.
        renderAgentMarkdown(self) catch {};

        // No placeholder to drop — the chunk handler creates the
        // agent line lazily, so an empty turn leaves no empty
        // line behind.
        self.pending_agent_line = null;
        self.pending_saw_text = false;
        self.thinking.pending = false;
        self.turn_started_ms = 0;
        ctx.redraw = true;
    }
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Root = @ptrCast(@alignCast(ptr));
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;

    // Layout (top → bottom):
    //   header                       Header.bannerRows(width)
    //   history                      flex (whatever's left)
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

    // Header collapses to zero rows when the terminal is too
    // short to fit it alongside the bottom stack.
    const bottom_stack: u16 = thinking_rows + hint_rows + input_rows + status_rows + trailing_rows;
    const requested_header: u16 = Header.bannerRows(width);
    const header_rows: u16 = if (height > bottom_stack + requested_header)
        requested_header
    else if (height > bottom_stack)
        height - bottom_stack
    else
        0;

    const reserved: u16 = header_rows + bottom_stack;
    const history_rows: u16 = if (height > reserved) height - reserved else 0;

    const children = try ctx.arena.alloc(vxfw.SubSurface, 7);
    const surface = try vxfw.Surface.initWithChildren(
        ctx.arena,
        self.widget(),
        .{ .width = width, .height = height },
        children,
    );

    var cur_row: u16 = 0;

    // Header.
    {
        const s = try self.header.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = header_rows },
        ));
        surface.children[0] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += header_rows;
    }

    // History at full width. Earlier we kept a 1-cell side margin
    // for visual breathing room, but that left a tiny untinted
    // gutter on user-message tints (which span their child surface
    // edge to edge). Going flush keeps the user-message half-block
    // band lined up vertically with the input panel below.
    {
        const view: History = .{
            .lines = self.history.items,
            .scroll_offset = self.scroll_offset,
        };
        const s = try view.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = history_rows },
        ));
        surface.children[1] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += history_rows;
    }

    // Thinking row — collapses to 0 when not pending.
    {
        const s = try self.thinking.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = thinking_rows },
        ));
        surface.children[2] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += thinking_rows;
    }

    // Hint row.
    {
        const s = try self.hint.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = hint_rows },
        ));
        surface.children[3] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
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
        surface.children[4] = .{ .origin = .{ .row = cur_row, .col = 0 }, .surface = s, .z_index = 0 };
        cur_row += input_rows;
    }

    // Status bar sits above the trailing rows (slash menu when
    // open, otherwise just the bottom pad). Pinned by absolute
    // row so a stray off-by-one earlier in the stack can't hide
    // the footer.
    const status_origin: u16 = height - trailing_rows - status_rows;
    {
        const s = try self.status_bar.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = status_rows },
        ));
        surface.children[5] = .{ .origin = .{ .row = status_origin, .col = 0 }, .surface = s, .z_index = 0 };
    }

    // Slash-command popup below the status bar. When the menu is
    // hidden, it draws as a zero-height surface and the bottom
    // pad fills the gap.
    {
        const s = try menu.widget().draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = width, .height = menu_rows },
        ));
        surface.children[6] = .{ .origin = .{ .row = status_origin + status_rows, .col = 0 }, .surface = s, .z_index = 0 };
    }

    return surface;
}

/// Walk recent agent lines and re-render their text as markdown.
/// Spans-bearing lines are skipped (already processed). Failures are
/// silent: the line keeps its raw text and renders unstyled, which is
/// strictly less helpful but never wrong.
fn renderAgentMarkdown(self: *Root) !void {
    var i: usize = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const line = &self.history.items[i];
        // Stop scanning once we cross a non-agent line: earlier
        // agent lines from prior turns already had their markdown
        // baked in on a previous ue_done. This keeps the loop O(N)
        // in lines added _this_ turn, not total history.
        if (line.role != .agent) break;
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
    try text.appendSlice(allocator, name);
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

/// (Re)render `entry.text` from the tool's structured fields.
/// Idempotent — call after every state change (done lands,
/// expand toggles, args update from a coalesced retry).
fn renderToolLine(allocator: std.mem.Allocator, entry: *tui.Line) !void {
    const name = entry.tool_name orelse return;
    entry.text.clearRetainingCapacity();
    try renderToolHeader(allocator, &entry.text, name, entry.tool_args orelse "");

    const has_full = if (entry.tool_full) |f| f.len > 0 else false;
    if (!has_full) return;

    if (entry.tool_expanded) {
        // Expanded: every output line gets the `└` continuation.
        const trimmed = std.mem.trimEnd(u8, entry.tool_full.?, "\n");
        if (trimmed.len == 0) return;
        try entry.text.append(allocator, '\n');
        var iter = std.mem.splitScalar(u8, trimmed, '\n');
        var first = true;
        while (iter.next()) |body_line| {
            if (!first) try entry.text.append(allocator, '\n');
            first = false;
            try entry.text.appendSlice(allocator, "  \u{2514} ");
            try entry.text.appendSlice(allocator, body_line);
        }
    } else if (entry.tool_summary) |s| {
        // Collapsed: one line, the summary.
        if (s.len == 0) return;
        try entry.text.append(allocator, '\n');
        try entry.text.appendSlice(allocator, "  \u{2514} ");
        try entry.text.appendSlice(allocator, s);
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
