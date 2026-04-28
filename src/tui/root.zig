//! Full-screen chat TUI.
//!
//! Launched by `tigerclaw` (no subcommand). Connects to a locally
//! running gateway on 127.0.0.1:8765 and presents a chat loop with
//! an agent switcher — message history scrolls above, text input
//! below, status bar in between.
//!
//! # Design
//!
//! * Built on libvaxis (vendored in packages/vaxis).
//! * Event-driven — vaxis's Loop pushes key presses, resize, and
//!   focus events into a queue; a worker thread pushes
//!   `turn_chunk` / `turn_done` / `turn_error` variants for the
//!   active turn, and a ticker thread pushes `tick` while pending
//!   so the spinner animates without needing input. The main loop
//!   stays responsive for keys and resizes while the HTTP
//!   round-trip runs.
//! * History is an ArrayList of lines with per-line text stored in
//!   its own ArrayList(u8) so streamed chunks can append in place
//!   without reallocating the history entry.
//!
//! # Gateway contract
//!
//! POST /sessions/<agent>/turns with `{"message": "..."}` and
//! `Accept: text/event-stream`. The gateway replies with a sequence
//! of `event: token` frames (one per source line) followed by a
//! single `event: done`. The SSE frame grammar is duplicated from
//! `cli/commands/agent.zig` so the worker can emit one vaxis event
//! per frame instead of rendering a concatenated string.
//!
//! # Agent switcher
//!
//! On launch, scans `$HOME/.tigerclaw/agents/` for subdirectories
//! and treats each as a selectable agent. `Ctrl-N` / `Ctrl-P`
//! cycle forward / back; `Ctrl-E` opens an inline picker overlay.
//! If the scan returns nothing, the caller-supplied default agent
//! is the only option.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
pub const md = @import("md.zig");
pub const ansi = @import("ansi.zig");
const tool_preview = @import("tool_preview.zig");
const gateway_runner_mod = @import("gateway_runner.zig");
const live_runner = @import("../cli/commands/live_runner.zig");
const harness = @import("../harness/root.zig");
const HeaderWidget = @import("widgets/header.zig");

test {
    // Ensure md tests are discovered when the unit-test binary
    // walks references from this file.
    std.testing.refAllDecls(md);
    std.testing.refAllDecls(ansi);
    std.testing.refAllDecls(tool_preview);
    std.testing.refAllDecls(@import("widgets/history.zig"));
    // Pull in tests from the RootWidget surface and the mention
    // parser. Both files have unit tests that the package-level
    // discovery would otherwise skip — `tui/root.zig` doesn't
    // import them at decl level today.
    std.testing.refAllDecls(@import("widgets/root.zig"));
    std.testing.refAllDecls(@import("mention.zig"));
    // Force body compilation of every vxfw widget in the subset
    // we plan to migrate onto, so any 0.16 API regression in
    // packages/vaxis/src/vxfw surfaces here at build time instead
    // of blowing up mid-refactor.
    _ = &vxfw.App.init;
    _ = &vxfw.App.run;
    _ = &vxfw.FlexColumn.draw;
    _ = &vxfw.Text.draw;
    _ = &vxfw.Border.draw;
    _ = &vxfw.Padding.draw;
    _ = &vxfw.Spinner.draw;
    // Pull the vxfw smoke test's public fn into the compile graph
    // too, so any widget wiring we add there surfaces at build time.
    _ = &@import("vxfw_hello.zig").run;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// One decoded SSE chunk frame. Slice is heap-allocated on the
    /// worker thread; the main loop takes ownership and frees after
    /// appending to history.
    turn_chunk: []u8,
    /// A tool call is about to run. Both slices are heap-allocated
    /// and owned by the main loop after receipt.
    turn_tool_start: ToolStartPayload,
    /// A tool call completed. All slices heap-allocated + owned.
    turn_tool_done: ToolDonePayload,
    /// Stream terminator. Re-enables input.
    turn_done,
    /// Worker hit a transport / protocol error. Slice is owned and
    /// freed by the main loop after rendering as a system line.
    turn_error: []u8,
    /// Low-frequency heartbeat from the spinner ticker while a turn
    /// is pending. Drives spinner animation without relying on
    /// incoming keys.
    tick,
};

const ToolStartPayload = struct { id: []u8, name: []u8, args_summary: []u8 };
const ToolDonePayload = struct { id: []u8, name: []u8, output: []u8 };

/// Re-export of the widget namespace. Tests drive widgets like
/// `RootWidget` directly via \`tigerclaw.tui.widgets.root\`.
pub const widgets = struct {
    pub const root = @import("widgets/root.zig");
    pub const header = @import("widgets/header.zig");
    pub const history = @import("widgets/history.zig");
    pub const input = @import("widgets/input.zig");
    pub const thinking = @import("widgets/thinking.zig");
    pub const hint = @import("widgets/hint.zig");
    pub const status_bar = @import("widgets/status_bar.zig");
    pub const user_message = @import("widgets/user_message.zig");
};

pub const Line = struct {
    role: Role,
    text: std.ArrayList(u8),
    /// Speaker name for the leading `[ name ]` pill. Set on `.user`
    /// and `.agent` lines (`"Omkar"` / `"tiger"` / `"sage"` etc).
    /// Null on `.system` and `.tool` rows — those don't get a pill,
    /// they live in their own visual class. Owned heap slice.
    speaker: ?[]u8 = null,
    /// Style spans over `text`. Non-null only for agent replies
    /// that have finished streaming and been re-parsed as
    /// markdown; streaming in progress keeps this null so the
    /// renderer falls back to a flat style.
    spans: ?[]md.Span = null,
    /// Set on `tool` lines only — the Anthropic tool-call id the
    /// line represents. `turn_tool_done` uses this to find its
    /// matching pending line and promote it to the done state
    /// without having to pattern-match on rendered text.
    tool_id: ?[]u8 = null,
    /// Tool-call display fields. Set on `tool` lines after
    /// `turn_tool_done` lands; used when re-rendering on
    /// expand/collapse toggles. Owned heap slices.
    tool_name: ?[]u8 = null,
    /// One-line `args_summary` from the runner (e.g. `npm test`,
    /// `/path/to/file.zig`). Empty when the tool takes no args.
    tool_args: ?[]u8 = null,
    /// First-line preview shown when the row is collapsed.
    tool_summary: ?[]u8 = null,
    /// Full body shown when the row is expanded. Lines are
    /// joined with `\n`; the renderer prefixes each with the
    /// `└` continuation glyph.
    tool_full: ?[]u8 = null,
    /// True when the user has expanded this row (Ctrl-B). Default
    /// false — collapsed by default to keep the chat readable.
    tool_expanded: bool = false,
    /// Status bullet color. `.running` paints white while the tool
    /// is in flight, `.ok` green on a clean finish, `.err` red on
    /// dispatch failure. Cancelled tools stay `.ok` — the cancel
    /// is the user's action, not a tool failure, and we already
    /// surface "[cancelled by user]" as the summary.
    tool_status: ToolStatus = .running,
    /// Turn this tool was dispatched in. Sibling tool lines in the
    /// same turn render as a connected tree (`├─` / `└─` prefixes);
    /// the last tool line in a turn switches to the `└─` glyph
    /// once the turn finishes via `markLastToolInTurn`.
    tool_turn_id: u32 = 0,
    /// True once the turn this tool belongs to has ended *and* this
    /// is the tail tool of that turn. Drives `└─` vs `├─` selection.
    tool_is_last_in_turn: bool = false,
    /// Wall-clock time the tool dispatch began (ms since vaxis epoch).
    /// Used to compute `tool_duration_ms` on done.
    tool_started_ms: i64 = 0,
    /// Duration of the dispatch in milliseconds. Zero pre-finish; set
    /// on `turn_tool_done`. Rendered as `Completed in 1.0s`.
    tool_duration_ms: u64 = 0,
    /// Most-recent line of live progress output emitted by the tool
    /// (today: bash stdout/stderr). Owned heap slice; null until the
    /// first progress event lands. Cleared once the tool finishes.
    tool_progress_tail: ?[]u8 = null,
    /// Banner-row index (0-based) for `.banner` lines. The history
    /// renderer uses this to pick a gradient color from a fixed
    /// palette so each wordmark row paints in its own band as the
    /// banner scrolls. Ignored for every other role.
    banner_row: u8 = 0,

    pub const ToolStatus = enum { running, ok, err };

    pub fn deinitSpans(self: *Line, allocator: std.mem.Allocator) void {
        if (self.spans) |s| {
            allocator.free(s);
            self.spans = null;
        }
    }

    pub fn deinitSpeaker(self: *Line, allocator: std.mem.Allocator) void {
        if (self.speaker) |s| {
            allocator.free(s);
            self.speaker = null;
        }
    }

    pub fn deinitToolId(self: *Line, allocator: std.mem.Allocator) void {
        if (self.tool_id) |id| {
            allocator.free(id);
            self.tool_id = null;
        }
    }

    pub fn deinitToolFields(self: *Line, allocator: std.mem.Allocator) void {
        if (self.tool_name) |s| allocator.free(s);
        if (self.tool_args) |s| allocator.free(s);
        if (self.tool_summary) |s| allocator.free(s);
        if (self.tool_full) |s| allocator.free(s);
        if (self.tool_progress_tail) |s| allocator.free(s);
        self.tool_name = null;
        self.tool_args = null;
        self.tool_summary = null;
        self.tool_full = null;
        self.tool_progress_tail = null;
    }

    pub const Role = enum { user, agent, system, tool, banner };
};

pub const Options = struct {
    agent: []const u8 = "tiger",
    /// Caller-resolved `$HOME`. Used for local agent discovery and
    /// skill/config commands; agent turns now flow through the gateway.
    home: []const u8 = "",
    /// Gateway base URL. TUI acts as a localhost client of the daemon.
    base_url: []const u8 = "http://127.0.0.1:8765",
    bearer: ?[]const u8 = null,
    /// Display name on the user's `[ name ]` pill. Resolved by
    /// `runTuiLocal` from `~/.tigerclaw/config.json:user_name`,
    /// then `$USER`, then this fallback.
    user_name: []const u8 = "Omkar",
    /// When true, the cross-agent dispatch logger appends every
    /// dispatch event to `/tmp/tigerclaw-tui.log`. Off by default
    /// so production TUI runs don't litter `/tmp`. Toggled by
    /// `--debug` on the CLI or `TIGERCLAW_DEBUG=1` in the env.
    debug: bool = false,
};

const EventLoop = vaxis.Loop(Event);

/// Tiger palette — warm amber + black-stripe charcoal + cream on
/// black, inspired by a Bengal tiger's coat. 24-bit truecolor; the
/// terminal needs `COLORTERM=truecolor` (default on iTerm2, Ghostty,
/// WezTerm, Kitty, modern Terminal.app). On a non-truecolor term the
/// sequences gracefully degrade to the nearest 256-color index.
pub const palette = struct {
    // Core palette. Tigerclaw still keeps an amber accent for the
    // brand banner and the prompt, but body text leans neutral so
    // the eye isn't fighting saturated colours line after line.
    pub const orange: vaxis.Color = .{ .rgb = .{ 0xFF, 0x8C, 0x1A } }; // tiger orange (banner only)
    const cream: vaxis.Color = .{ .rgb = .{ 0xEC, 0xE4, 0xDA } }; // warm cream (agent body)
    const sand: vaxis.Color = .{ .rgb = .{ 0xC9, 0xB8, 0xA0 } }; // muted sand (user echo)
    const stripe: vaxis.Color = .{ .rgb = .{ 0x1A, 0x12, 0x10 } }; // charcoal stripe (chip bg)
    const smoke: vaxis.Color = .{ .rgb = .{ 0x7A, 0x73, 0x6C } }; // medium grey (system / hints)
    const dim: vaxis.Color = .{ .rgb = .{ 0x8E, 0x88, 0x7E } }; // tool grey
    const ember: vaxis.Color = .{ .rgb = .{ 0xE8, 0x60, 0x3C } }; // ember red (errors / busy)
    const link: vaxis.Color = .{ .rgb = .{ 0xC0, 0x90, 0x55 } }; // dim link amber
    const code_fg: vaxis.Color = .{ .rgb = .{ 0xD9, 0xCB, 0xB4 } }; // soft cream for code
    const code_bg: vaxis.Color = .{ .rgb = .{ 0x22, 0x22, 0x22 } }; // neutral dark grey
    const heading: vaxis.Color = .{ .rgb = .{ 0xE7, 0xC0, 0x82 } }; // softened heading amber
    /// Panel background -- the tinted block under the
    /// input box and the user-message echoes. Needs a noticeable
    /// step up from the terminal default black so the half-block
    /// trick (`▄`/`▀` painted in this colour over a default-bg
    /// cell) reads as a half-cell of tint rather than as a muddy
    /// uniform row. With too little contrast the eye can't tell
    /// the half-blocks from the solid content row, and the band
    /// looks like one thick brick instead of a slim floating panel.
    const panel_bg: vaxis.Color = .{ .rgb = .{ 0x3D, 0x3D, 0x3D } };
    /// Status-bar background -- a half-shade lighter than the panel
    /// so the bar reads as a footer rather than part of the input.
    const status_bg: vaxis.Color = .{ .rgb = .{ 0x1E, 0x1E, 0x1E } };
    /// Caution / warning accent (locked / plan mode) — a
    /// muted yellow that doesn't fight the tiger orange.
    const caution: vaxis.Color = .{ .rgb = .{ 0xC9, 0xB8, 0xA0 } };

    const title: vaxis.Style = .{ .fg = stripe, .bg = orange, .bold = true };
    const agent_chip: vaxis.Style = .{ .fg = stripe, .bg = sand, .bold = true };
    const status_idle: vaxis.Style = .{ .fg = dim, .bold = true };
    const status_busy: vaxis.Style = .{ .fg = ember, .bold = true };
    const separator: vaxis.Style = .{ .fg = smoke };
    /// User echo: muted sand, no hot saturation. Bold keeps it
    /// distinct from agent text without fighting the eye.
    pub const user: vaxis.Style = .{ .fg = sand, .bold = true };
    pub const agent: vaxis.Style = .{ .fg = cream };
    /// System notices: dim grey, no italic — italics in monospace
    /// fonts often render as oblique slants that look broken,
    /// especially on the speaker glyph itself.
    pub const system: vaxis.Style = .{ .fg = smoke };
    /// Tool-call trace lines. Plain dim grey — clearly subordinate
    /// to the conversation but readable. No green, no italic.
    pub const tool: vaxis.Style = .{ .fg = dim };

    /// Status-bullet colors for `● Tool(args)` headers. White
    /// while running, green on success, red on dispatch failure.
    /// Bold so the dot pops against the dim body text. RGB
    /// constants picked to read well on both light and dark
    /// terminals — the green leans toward emerald, the red
    /// toward terracotta to keep the tiger palette warm.
    pub const tool_bullet_running: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xE0, 0xE0, 0xE0 } }, .bold = true };
    pub const tool_bullet_ok: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x4A, 0xC8, 0x76 } }, .bold = true };
    pub const tool_bullet_err: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xD9, 0x4F, 0x4F } }, .bold = true };
    pub const prompt: vaxis.Style = .{ .fg = orange, .bold = true };
    pub const hint: vaxis.Style = .{ .fg = smoke };
    /// Input box: cream foreground on the lifted panel background.
    pub const input_text: vaxis.Style = .{ .fg = cream, .bg = panel_bg };
    /// Muted prompt for the input panel and the user-message echo
    /// in history. Dim sand keeps the `›` from screaming over the
    /// content the user is composing.
    pub const input_prompt: vaxis.Style = .{ .fg = sand, .bg = panel_bg };
    /// Ghost placeholder: dim grey, same panel bg.
    pub const input_ghost: vaxis.Style = .{ .fg = smoke, .bg = panel_bg };
    /// Empty cell of the input panel — paints the bg tint.
    pub const input_blank: vaxis.Style = .{ .bg = panel_bg };
    /// Status bar: dim text on a slightly darker bg than the input
    /// panel, so the eye reads "footer" instead of "another input".
    pub const status_label: vaxis.Style = .{ .fg = smoke, .bg = status_bg };
    pub const status_value: vaxis.Style = .{ .fg = cream, .bg = status_bg };
    pub const status_blank: vaxis.Style = .{ .bg = status_bg };
    /// Status caution text (e.g. `untrusted`).
    pub const status_caution: vaxis.Style = .{ .fg = caution, .bg = status_bg };
    const picker_border: vaxis.Style = .{ .fg = orange };
    const picker_item: vaxis.Style = .{ .fg = cream };
    const picker_item_selected: vaxis.Style = .{ .fg = stripe, .bg = orange, .bold = true };

    // Markdown span overlays. Each function composes the span style
    // on top of the caller's base style (typically `palette.agent`)
    // so text still reads as the speaker's line colour with the
    // markdown flavour applied on top.
    pub fn mdStyle(base: vaxis.Style, kind: md.StyleKind) vaxis.Style {
        var s = base;
        switch (kind) {
            .plain => {},
            .bold => s.bold = true,
            .italic => s.italic = true,
            .code => {
                s.fg = code_fg;
                s.bg = code_bg;
            },
            .link => {
                s.fg = link;
                s.ul_style = .single;
            },
            .heading => {
                s.fg = heading;
                s.bold = true;
            },
            .block_quote => s.fg = smoke,
            .diff_add => s.fg = .{ .rgb = .{ 0x4A, 0xC8, 0x76 } },
            .diff_del => s.fg = .{ .rgb = .{ 0xD9, 0x4F, 0x4F } },
            .diff_hunk => {
                s.fg = heading;
                s.bold = true;
            },
        }
        return s;
    }
};

const spinner_frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

const RootWidget = @import("widgets/root.zig");

/// New TUI entry point driven by `vxfw.App.run`.
fn runVxfw(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    // Agent roster. Same logic as the old run() — the vxfw path
    // needs the default agent name to hand to RootWidget.
    var agents = AgentList.init(allocator);
    defer agents.deinit();
    try agents.loadFromDisk(io, opts.home);
    const default_index = agents.findOrAppend(opts.agent) catch 0;
    const default_agent = agents.name(default_index);

    var gateway_runner = gateway_runner_mod.GatewayRunner.init(allocator, io, opts.base_url, opts.bearer);
    defer gateway_runner.deinit();
    var agent_runner: harness.AgentRunner = gateway_runner.runner();

    var app = try vxfw.App.init(allocator, io);
    defer app.deinit();
    // Force legacy SGR + RGB caps, same as the hand-rolled path,
    // so Terminal.app renders the tiger palette correctly.
    app.vx.sgr = .legacy;
    app.vx.caps.rgb = true;

    // Read the active agent's model from disk so the status bar
    // shows something the user can recognise (e.g. `claude-haiku-4-5`)
    // and so `modelMaxContext` in RootWidget.init can populate the
    // context-window cap. Falls back to the gateway URL when the
    // manifest is missing — keeps boot working in unconfigured envs.
    const model_line = readActiveAgentModel(allocator, io, opts.home, default_agent) catch null orelse
        try std.fmt.allocPrint(allocator, "gateway {s}", .{opts.base_url});
    defer allocator.free(model_line);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len);
    // `getcwd` writes a NUL-terminated path into cwd_buf; find
    // the terminator to get the length.
    const cwd: []const u8 = if (cwd_ptr != null) blk: {
        const n = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_buf.len;
        break :blk cwd_buf[0..n];
    } else "";

    // Pull cross-agent dispatch knobs from the user's config. Failure
    // is silently absorbed — defaults stand and the TUI still boots.
    const max_calls_opt = readAutoDispatchMaxCalls(allocator, io, opts.home);

    var root = RootWidget.init(allocator, .{
        .agent_name = default_agent,
        .model_line = model_line,
        .workspace = cwd,
        .home = opts.home,
        .user_name = opts.user_name,
        .agent_names = agents.items(),
        .io = io,
        .auto_dispatch_max_calls = max_calls_opt,
    });
    defer root.deinit();
    root.wireSubmit();
    root.attachRunner(&agent_runner, &app);
    // Emit the scrolling banner once at the top of history. It
    // replaces the old pinned `Header` widget — same wordmark and
    // gradient, but it scrolls along with the chat so the area
    // above the input is clean for the upper status bar / live
    // tool state once the conversation grows. Query the winsize
    // directly here so a narrow terminal gets the compact "TC"
    // wordmark instead of a wrapping wide one. vaxis hasn't yet
    // sized its screen at this point — the App.run loop is what
    // fires the first resize event — so we go to the kernel.
    const launch_width: u16 = blk: {
        const ws = vaxis.Tty.getWinsize(app.tty.fd) catch break :blk 0;
        break :blk ws.cols;
    };
    root.appendBanner(launch_width) catch {};
    // Forward sandbox toggles (/lock, /unlock, /plan) through the
    // gateway HTTP runner so the daemon's in-process LiveAgentRunner
    // adopts the same policy. Without this bridge the TUI's status
    // bar would say "unlocked" while the daemon — which actually
    // dispatches every tool — kept whatever sandbox state it
    // booted with. Ask-gate has no gateway endpoint today, so we
    // wire a no-op for that slot; the gateway runner's defaults
    // are what tools see.
    root.attachSandbox(&agent_runner, gatewaySandboxAdapter, gatewayAskGateNoop);

    try app.run(root.widget(), .{});
}

fn gatewaySandboxAdapter(ctx: *anyopaque, mode: u8, path: []const u8) void {
    const runner: *harness.AgentRunner = @ptrCast(@alignCast(ctx));
    const m: harness.agent_runner.SandboxMode = @enumFromInt(mode);
    runner.setSandbox(m, path) catch {};
}

fn gatewayAskGateNoop(_: *anyopaque, _: bool) void {}

fn sandboxAdapter(ctx: *anyopaque, mode: u8, path: []const u8) void {
    const live: *live_runner.LiveAgentRunner = @ptrCast(@alignCast(ctx));
    const m: live_runner.LiveAgentRunner.SandboxMode = @enumFromInt(mode);
    live.setSandboxMode(m, path) catch {};
}

fn askGateAdapter(ctx: *anyopaque, value: bool) void {
    const live: *live_runner.LiveAgentRunner = @ptrCast(@alignCast(ctx));
    live.setAskUserGate(value);
}

fn askUserPostAdapter(ctx: *anyopaque, allocator: std.mem.Allocator, question: []const u8) anyerror!void {
    const root: *RootWidget = @ptrCast(@alignCast(ctx));
    return root.askUserPost(allocator, question);
}

fn askUserTakeAdapter(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    const root: *RootWidget = @ptrCast(@alignCast(ctx));
    return root.askUserTake(allocator);
}

fn askUserCancelAdapter(ctx: *anyopaque) void {
    const root: *RootWidget = @ptrCast(@alignCast(ctx));
    root.askUserCancel();
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    // Flip the side-channel dispatch logger gate before any worker
    // thread is spawned. The logger has process-global state, so
    // setting it once here is enough for both vxfw and legacy paths.
    @import("widgets/root.zig").dispatch_log.setEnabled(opts.debug);
    // vxfw path is the default. Set \`TIGERCLAW_VXFW=0\` to fall
    // back to the hand-rolled implementation — kept around as a
    // rollback escape hatch while the vxfw port soaks. The old
    // path will be deleted once we've lived on vxfw for a while.
    const use_legacy = blk: {
        const v = std.c.getenv("TIGERCLAW_VXFW") orelse break :blk false;
        const s = std.mem.span(v);
        break :blk s.len > 0 and s[0] == '0';
    };
    if (!use_legacy) return runVxfw(allocator, io, opts);

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);
    // Switch to the legacy SGR encoding (semicolon-separated sub-
    // parameters) so truecolor paints on macOS Terminal.app. The
    // default is `.standard` — colon-separated, per ITU-T T.416 —
    // which Terminal.app silently drops on the floor. iTerm2 /
    // Ghostty / WezTerm accept both; the legacy form is the
    // universally-compatible one. (See packages/vaxis/src/ctlseqs.zig
    // — `fg_rgb` vs `fg_rgb_legacy`.)
    vx.sgr = .legacy;
    vx.caps.rgb = true;

    var loop: EventLoop = .{ .vaxis = &vx, .tty = &tty };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    var input = vaxis.widgets.TextInput.init(allocator);
    defer input.deinit();

    var history: std.ArrayList(Line) = .empty;
    defer {
        for (history.items) |*l| {
            l.text.deinit(allocator);
            l.deinitSpans(allocator);
            l.deinitToolId(allocator);
            l.deinitToolFields(allocator);
        }
        history.deinit(allocator);
    }

    // Load the agent roster. On failure we still run with the
    // caller-supplied default so the TUI is usable against any
    // configuration.
    var agents = AgentList.init(allocator);
    defer agents.deinit();
    try agents.loadFromDisk(io, opts.home);
    const default_index = agents.findOrAppend(opts.agent) catch 0;
    var selected: usize = default_index;

    // Load the in-process runner for the default agent. The TUI owns
    // this lifecycle; swapping agents tears the runner down and
    // rebuilds it so each agent sees its own system prompt, model
    // config, and workspace sandbox. If the initial load fails
    // (missing config.json, unknown provider) we surface the error
    // to the user and exit so they can fix it — the TUI can't do
    // useful work without a runner.
    var live = live_runner.LiveAgentRunner.load(allocator, io, agents.name(selected), "", opts.home) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "tigerclaw tui: could not load agent '{s}': {s}\n", .{ agents.name(selected), @errorName(err) });
        defer allocator.free(msg);
        _ = std.c.write(2, msg.ptr, msg.len);
        return err;
    };
    defer live.deinit();
    var agent_runner: harness.AgentRunner = live.runner();
    // Agent-switching via Ctrl-N / Ctrl-P / picker is still wired to
    // `selected` for display purposes, but the in-process runner is
    // pinned to the agent it was loaded with. Hot-reload on switch
    // is future work; for now the user has to restart the TUI to
    // change agents. Silence the never-mutated warning — a later
    // commit will mutate this when reload lands.
    _ = &agent_runner;

    try appendAgentLine(&history, allocator, agents.items(), selected);

    var spinner_tick: u64 = 0;
    var picker_open: bool = false;
    var picker_cursor: usize = selected;

    // Ticker lifecycle — only alive while a turn is pending. The
    // main thread owns the flag and joins the ticker on done/error.
    var ticker_stop: std.atomic.Value(bool) = .init(false);
    var ticker_thread: ?std.Thread = null;

    var pending: bool = false;
    var stopping: bool = false;
    var pending_agent_line: ?usize = null;
    var pending_saw_text: bool = false;

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
                    ticker_stop.store(true, .release);
                    if (ticker_thread) |t| t.join();
                    return;
                }

                // ESC during a pending turn cooperatively cancels.
                // The runner's vtable.cancel flips the internal
                // cancel_flag; the streaming reader and tool
                // dispatch loop pick it up at their next checkpoint
                // and unwind the turn with a "[cancelled]" marker.
                // Idle ESC is a no-op (no in-flight work to abort).
                if (key.matches(vaxis.Key.escape, .{}) and pending and !picker_open) {
                    if (!stopping) {
                        stopping = true;
                        try appendLine(&history, allocator, .system, "∙ stopping turn…");
                    }
                    agent_runner.cancel(0);
                    continue;
                }

                if (picker_open) {
                    const before = selected;
                    handlePickerKey(key, &picker_open, &picker_cursor, &selected, agents.items());
                    if (selected != before) {
                        try appendAgentLine(&history, allocator, agents.items(), selected);
                    }
                } else if (key.matches('e', .{ .ctrl = true }) and !pending) {
                    picker_cursor = selected;
                    picker_open = true;
                } else if (key.matches('n', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = (selected + 1) % agents.count();
                    try appendAgentLine(&history, allocator, agents.items(), selected);
                } else if (key.matches('p', .{ .ctrl = true }) and !pending and agents.count() > 1) {
                    selected = if (selected == 0) agents.count() - 1 else selected - 1;
                    try appendAgentLine(&history, allocator, agents.items(), selected);
                } else if (key.matches(vaxis.Key.enter, .{}) and !pending) {
                    const typed = try currentInput(allocator, &input);
                    defer allocator.free(typed);
                    if (typed.len == 0) continue;

                    // Slash-command interception — keeps the wire
                    // path (agent_line + worker spawn) reserved for
                    // actual agent turns. Leading whitespace is
                    // trimmed first so stray spaces from paste or
                    // accidental keystrokes still activate the
                    // command parser instead of being sent on to
                    // the agent as user text.
                    const trimmed = std.mem.trim(u8, typed, " \t");
                    if (std.mem.startsWith(u8, trimmed, "/")) {
                        input.clearAndFree();
                        try handleSlashCommand(
                            &history,
                            allocator,
                            &agents,
                            &selected,
                            trimmed,
                        );
                        continue;
                    }

                    const user_line = try makeLine(allocator, .user, typed);
                    try history.append(allocator, user_line);
                    input.clearAndFree();

                    // Reserve the agent line up front so streamed
                    // chunks have a stable slot to append to. The
                    // line starts empty; if the worker errors
                    // before any chunk lands it gets dropped.
                    const agent_line = try makeLine(allocator, .agent, "");
                    try history.append(allocator, agent_line);
                    pending_agent_line = history.items.len - 1;
                    pending_saw_text = false;
                    pending = true;

                    const message_copy = try allocator.dupe(u8, typed);
                    const ctx = try allocator.create(WorkerCtx);
                    // Use the agent's name as the session id so the
                    // runner's context engine keyed per-session still
                    // sees continuous history across turns. Swapping
                    // agents starts a new session naturally.
                    ctx.* = .{
                        .allocator = allocator,
                        .io = io,
                        .loop = &loop,
                        .runner = &agent_runner,
                        .session_id = agents.name(selected),
                        .message = message_copy,
                    };
                    const t = std.Thread.spawn(.{}, workerMain, .{ctx}) catch |err| {
                        allocator.free(message_copy);
                        allocator.destroy(ctx);
                        if (pending_agent_line) |idx| {
                            var dropped = history.orderedRemove(idx);
                            dropped.text.deinit(allocator);
                            dropped.deinitSpans(allocator);
                        }
                        pending_agent_line = null;
                        pending = false;
                        stopping = false;
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "! could not spawn worker: {s}",
                            .{@errorName(err)},
                        );
                        defer allocator.free(msg);
                        try appendLine(&history, allocator, .system, msg);
                        try drawFrame(allocator, &vx, writer, &input, history.items, agents.items(), selected, pending, spinner_tick, picker_open, picker_cursor);
                        continue;
                    };
                    t.detach();

                    // Start the spinner ticker. It posts `.tick`
                    // every 80ms until asked to stop.
                    ticker_stop.store(false, .release);
                    ticker_thread = std.Thread.spawn(.{}, tickerMain, .{TickerCtx{
                        .io = io,
                        .loop = &loop,
                        .stop = &ticker_stop,
                    }}) catch |err| blk: {
                        std.log.scoped(.tui).warn("spinner ticker spawn failed: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                } else if (!pending) {
                    try input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(allocator, writer, ws),
            .tick => spinner_tick +%= 1,
            .turn_chunk => |chunk| {
                defer allocator.free(chunk);
                if (pending_agent_line) |idx| {
                    var line = &history.items[idx];
                    try appendSanitizedUtf8(&line.text, allocator, chunk);
                    pending_saw_text = true;
                }
            },
            .turn_tool_start => |ts| {
                // Append a dim "pending" line before the next chunk
                // lands. The line's `tool_id` is held so
                // `turn_tool_done` can promote it in place. When
                // the runner provides an `args_summary` (e.g.
                // `npm test` for bash, `/path/file.zig` for
                // read_file), render `Bash(npm test) (pending)`
                // instead of bare `bash (pending)` so the user can
                // see what's running at a glance.
                defer allocator.free(ts.name);
                defer allocator.free(ts.args_summary);
                errdefer allocator.free(ts.id);

                var text: std.ArrayList(u8) = .empty;
                errdefer text.deinit(allocator);
                try text.appendSlice(allocator, ts.name);
                if (ts.args_summary.len > 0) {
                    try text.append(allocator, '(');
                    const max_summary: usize = 80;
                    const summary_taken = takeCols(ts.args_summary, max_summary);
                    try text.appendSlice(allocator, ts.args_summary[0..summary_taken.bytes]);
                    if (summary_taken.bytes < ts.args_summary.len) try text.appendSlice(allocator, "\u{2026}");
                    try text.append(allocator, ')');
                }
                try text.appendSlice(allocator, "   (pending)");

                try history.append(allocator, .{
                    .role = .tool,
                    .text = text,
                    .tool_id = ts.id,
                });
            },
            .turn_tool_done => |td| {
                defer allocator.free(td.id);
                defer allocator.free(td.name);
                defer allocator.free(td.output);

                // Find the most recent matching pending tool line.
                // Walking backwards keeps the cost tiny in practice
                // (the pending line is normally the last thing we
                // appended before this event fires).
                var match_idx: ?usize = null;
                var i: usize = history.items.len;
                while (i > 0) {
                    i -= 1;
                    const entry = &history.items[i];
                    if (entry.role != .tool) continue;
                    if (entry.tool_id) |id| {
                        if (std.mem.eql(u8, id, td.id)) {
                            match_idx = i;
                            break;
                        }
                    }
                }

                if (match_idx) |idx| {
                    var line = &history.items[idx];
                    line.text.clearRetainingCapacity();
                    try line.text.appendSlice(allocator, td.name);
                    try line.text.appendSlice(allocator, " \u{2192} ");
                    // Cap preview at 500 display columns (~5 wrapped
                    // rows on a narrow terminal, one on a wide one) —
                    // enough to see the shape of a fetch result or a
                    // read_file without a noisy tool hijacking the
                    // chat scroll. Full output is still in the
                    // agent's conversation context. \`takeCols\`
                    // walks by display columns so we don't cut a
                    // codepoint in half.
                    const max_preview: usize = 500;
                    const taken = takeCols(td.output, max_preview);
                    try line.text.appendSlice(allocator, td.output[0..taken.bytes]);
                    if (taken.bytes < td.output.len) try line.text.appendSlice(allocator, "\u{2026}");
                    line.deinitToolId(allocator);
                }
            },
            .turn_done => {
                if (!pending_saw_text) {
                    if (pending_agent_line) |idx| {
                        var dropped = history.orderedRemove(idx);
                        dropped.text.deinit(allocator);
                        dropped.deinitSpans(allocator);
                    }
                } else if (pending_agent_line) |idx| {
                    // Streaming done — re-parse the accumulated raw
                    // markdown with koino and attach the span list so
                    // the renderer paints bold/italic/code/etc. Guard
                    // against two failure modes silently losing the
                    // reply: parser error (fall through), and the
                    // walker returning empty text for a non-empty
                    // source (keep the raw bytes unchanged, skip
                    // styling). Either is better than an empty
                    // agent line with no explanation.
                    var line = &history.items[idx];
                    const had_text = line.text.items.len > 0;
                    if (md.render(allocator, line.text.items)) |rendered| {
                        if (rendered.text.len > 0 or !had_text) {
                            line.text.clearRetainingCapacity();
                            line.text.appendSlice(allocator, rendered.text) catch {};
                            line.deinitSpans(allocator);
                            line.spans = rendered.spans;
                            allocator.free(rendered.text);
                        } else {
                            // Parser returned nothing for non-empty
                            // input — keep the raw bytes and drop
                            // the (empty) spans slice.
                            allocator.free(rendered.text);
                            allocator.free(rendered.spans);
                        }
                    } else |_| {}
                }
                pending_agent_line = null;
                pending_saw_text = false;
                pending = false;
                stopping = false;
                ticker_stop.store(true, .release);
                if (ticker_thread) |t| {
                    t.join();
                    ticker_thread = null;
                }
            },
            .turn_error => |msg| {
                defer allocator.free(msg);
                if (pending_agent_line) |idx| {
                    if (!pending_saw_text) {
                        var dropped = history.orderedRemove(idx);
                        dropped.text.deinit(allocator);
                        dropped.deinitSpans(allocator);
                    }
                }
                try appendLine(&history, allocator, .system, msg);
                pending_agent_line = null;
                pending_saw_text = false;
                pending = false;
                ticker_stop.store(true, .release);
                if (ticker_thread) |t| {
                    t.join();
                    ticker_thread = null;
                }
            },
            else => {},
        }

        try drawFrame(allocator, &vx, writer, &input, history.items, agents.items(), selected, pending, spinner_tick, picker_open, picker_cursor);
    }
}

fn handlePickerKey(
    key: vaxis.Key,
    picker_open: *bool,
    cursor: *usize,
    selected: *usize,
    agents: []const []const u8,
) void {
    if (agents.len == 0) {
        picker_open.* = false;
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        picker_open.* = false;
    } else if (key.matches(vaxis.Key.enter, .{})) {
        selected.* = cursor.*;
        picker_open.* = false;
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        cursor.* = if (cursor.* == 0) agents.len - 1 else cursor.* - 1;
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        cursor.* = (cursor.* + 1) % agents.len;
    }
}

fn drawFrame(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    writer: anytype,
    input: *vaxis.widgets.TextInput,
    history: []const Line,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
    picker_open: bool,
    picker_cursor: usize,
) !void {
    // Wipe the cell buffer before every draw. Without this, cells from
    // a prior frame linger wherever the current draw does not paint
    // over them — which surfaces as the trailing `Z��` / `��8` junk
    // in the row above the input box when a streamed reply ends and
    // the old bytes are what's left in the grid.
    vx.window().clear();
    try draw(allocator, vx, input, history, agents, selected, pending, spinner_tick, picker_open, picker_cursor);
    try vx.render(writer);
    try writer.flush();
}

/// Join both halves of the TextInput's gap buffer into a contiguous
/// slice owned by the caller. Vaxis exposes `firstHalf` / `secondHalf`
/// directly rather than a flat `items` field.
fn currentInput(allocator: std.mem.Allocator, input: *vaxis.widgets.TextInput) ![]u8 {
    const a = input.buf.firstHalf();
    const b = input.buf.secondHalf();
    const out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn makeLine(allocator: std.mem.Allocator, role: Line.Role, text: []const u8) !Line {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendSanitizedUtf8(&buf, allocator, text);
    return .{ .role = role, .text = buf };
}

fn appendLine(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    role: Line.Role,
    text: []const u8,
) !void {
    const line = try makeLine(allocator, role, text);
    try history.append(allocator, line);
}

/// Push a one-line system banner naming the active agent. Used on
/// boot and whenever the operator flips to a different agent via
/// `Ctrl-N` / `Ctrl-P` / `/agent <name>`.
fn appendAgentLine(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    agents: []const []const u8,
    selected: usize,
) !void {
    const name = if (agents.len == 0) "default" else agents[selected];
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "agent: {s}", .{name}) catch "agent: ?";
    try appendLine(history, allocator, .system, text);
}

/// Dispatch a slash-command line. Recognised commands:
///   /agent              — list agents with a marker on the active one
///   /agent <name>       — switch to the named agent (must already be loaded)
///   /agents             — alias for `/agent`
///   /help               — short reminder of available commands
/// Unknown commands echo a one-line error. No command ever errors out
/// of the event loop; they always write a system line and return.
fn handleSlashCommand(
    history: *std.ArrayList(Line),
    allocator: std.mem.Allocator,
    agents: *AgentList,
    selected: *usize,
    line: []const u8,
) !void {
    // Trim the leading slash. Split on the first run of whitespace.
    const body = std.mem.trim(u8, line[1..], " \t");
    var tok_it = std.mem.tokenizeAny(u8, body, " \t");
    const cmd = tok_it.next() orelse {
        try appendLine(history, allocator, .system, "commands: /agent [name], /agents, /help");
        return;
    };

    if (std.mem.eql(u8, cmd, "help")) {
        try appendLine(history, allocator, .system, "commands: /agent [name], /agents, /help");
        return;
    }

    if (std.mem.eql(u8, cmd, "agent") or std.mem.eql(u8, cmd, "agents")) {
        const target = tok_it.next();
        if (target == null) {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll("agents:") catch {};
            for (agents.items(), 0..) |n, i| {
                const marker: []const u8 = if (i == selected.*) " *" else "  ";
                w.print(" {s}{s}", .{ marker, n }) catch {};
            }
            try appendLine(history, allocator, .system, w.buffered());
            return;
        }

        const want = target.?;
        for (agents.items(), 0..) |n, i| {
            if (std.mem.eql(u8, n, want)) {
                selected.* = i;
                try appendAgentLine(history, allocator, agents.items(), selected.*);
                return;
            }
        }

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "no such agent: {s}", .{want}) catch "no such agent";
        try appendLine(history, allocator, .system, msg);
        return;
    }

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: /{s}  (try /help)", .{cmd}) catch "unknown command";
    try appendLine(history, allocator, .system, msg);
}

fn draw(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    input: *vaxis.widgets.TextInput,
    history: []const Line,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
    picker_open: bool,
    picker_cursor: usize,
) !void {
    const win = vx.window();
    win.clear();

    // Row 0: header. Row 1: separator. Rest: history, then status
    // hint above a 3-row input box.
    try drawHeaderVxfw(allocator, vx, win, agents, selected, pending, spinner_tick);

    const header_rows: i32 = 2;
    const footer_rows: i32 = 4; // status hint + 3-row input box
    const history_height_i: i32 = @as(i32, @intCast(win.height)) - header_rows - footer_rows;
    if (history_height_i > 0) {
        const pane = win.child(.{
            .x_off = 1,
            .y_off = header_rows,
            .width = if (win.width > 2) win.width - 2 else win.width,
            .height = @intCast(history_height_i),
        });
        drawHistory(pane, history);
    }

    // Status-hint row intentionally omitted: it produced glyph
    // artefacts on macOS Terminal at narrow widths that I could not
    // fully attribute to a single source (printSegment wrap, width
    // detection races, or a terminal-response byte bleeding through
    // the input path). The header already shows the agent chip and
    // ready/thinking state, which covers the common case. Keybindings
    // are documented in tigerclaw --help.

    if (win.height >= 3) {
        // Orange-bordered input box so the prompt stands out against
        // the dim-smoke history scroll. A tiger-striped prompt glyph
        // sits at the left edge; placeholder text appears when the
        // buffer is empty so new users know what the box is for.
        const input_child = win.child(.{
            .x_off = 0,
            .y_off = @intCast(@as(i32, @intCast(win.height)) - 3),
            .width = win.width,
            .height = 3,
            .border = .{ .where = .all, .style = .{ .fg = palette.orange } },
        });
        _ = input_child.printSegment(
            .{ .text = "❯ ", .style = palette.prompt },
            .{ .row_offset = 0, .col_offset = 0 },
        );
        const input_inner = input_child.child(.{
            .x_off = 2,
            .y_off = 0,
            .width = if (input_child.width > 2) input_child.width - 2 else 1,
            .height = 1,
        });
        // Paint placeholder first when the buffer is empty, so the
        // input widget's subsequent draw only paints the cursor cell
        // (1 col) — leaving the placeholder text visible under it.
        const input_empty = input.buf.firstHalf().len + input.buf.secondHalf().len == 0;
        if (input_empty) {
            _ = input_inner.printSegment(
                .{ .text = "message the tiger…", .style = palette.hint },
                .{ .row_offset = 0, .col_offset = 1 },
            );
        }
        input.draw(input_inner);
    }

    if (picker_open and agents.len > 0) {
        drawPicker(win, agents, picker_cursor);
    }
}

/// Bridge between the vxfw widget and the hand-rolled draw loop.
///
/// Builds a per-frame arena (vxfw widgets allocate surface buffers
/// through the DrawContext arena and expect everything to be freed
/// together), instantiates the HeaderWidget with the current
/// agent/pending/spinner state, calls `widget.draw(ctx)` to produce
/// a Surface, then composites that Surface onto a child pane of the
/// vaxis window. This is the "surface.render(win, focused)" path
/// that `vxfw.App.run` normally drives — we're just doing it
/// manually until the full migration lands.
fn drawHeaderVxfw(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    win: vaxis.Window,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
) !void {
    const agent_name = if (agents.len > 0) agents[selected] else "—";

    _ = pending;
    _ = spinner_tick;
    const hdr: HeaderWidget = .{
        .agent_name = agent_name,
    };

    // vxfw allocates Surface cell buffers out of the DrawContext's
    // arena. Use a throwaway per-frame arena so there's no free
    // bookkeeping; it releases everything after this function
    // returns.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 0, .height = 0 },
        .max = .{
            .width = @intCast(win.width),
            .height = 2,
        },
        .cell_size = .{
            .width = if (vx.screen.width > 0) vx.screen.width_pix / vx.screen.width else 8,
            .height = if (vx.screen.height > 0) vx.screen.height_pix / vx.screen.height else 16,
        },
    };

    const surface = try hdr.widget().draw(ctx);

    // Composite the widget's Surface into the top two rows of the
    // window. `Surface.render` walks the cell buffer and calls
    // `win.writeCell` for each occupied cell — the same primitive
    // the hand-rolled `drawHeader` used directly.
    const pane = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = surface.size.width,
        .height = surface.size.height,
    });
    surface.render(pane, hdr.widget());
}

fn drawHeader(
    win: vaxis.Window,
    agents: []const []const u8,
    selected: usize,
    pending: bool,
    spinner_tick: u64,
) void {
    // Left: title. Kept ASCII-only — the previous emoji-prefixed
    // version triggered grapheme-width races on some terminals
    // that corrupted the right-side chip area during rapid
    // pending→ready transitions.
    _ = win.printSegment(
        .{ .text = "  tigerclaw  ", .style = palette.title },
        .{ .row_offset = 0, .col_offset = 0 },
    );

    // Right: agent chip + status chip, right-justified.
    var chip_buf: [128]u8 = undefined;
    const agent_name = if (agents.len > 0) agents[selected] else "—";
    const chip = std.fmt.bufPrint(&chip_buf, " {s} ", .{agent_name}) catch " agent ";

    const spinner = spinner_frames[@intCast(spinner_tick % spinner_frames.len)];
    var status_buf: [64]u8 = undefined;
    // Pad both labels to the same display width so the transition
    // from "thinking" → "ready" doesn't leave stale cells past the
    // right edge of the shorter string. vaxis's differential render
    // sometimes decides a cell's unchanged when the style flips back
    // and forth, which leaves the trailing "ng" of "thinking" bleeding
    // into "ready ". Same width in both states = no residue.
    const status_text = if (pending)
        (std.fmt.bufPrint(&status_buf, " {s} thinking ", .{spinner}) catch " … ")
    else
        " ● ready    ";

    const chip_len: usize = measureCols(chip);
    const status_len: usize = measureCols(status_text);
    const width: usize = @intCast(win.width);

    if (width > chip_len + status_len + 1) {
        const chip_col: u16 = @intCast(width - status_len - chip_len - 1);
        const status_col: u16 = @intCast(width - status_len);
        _ = win.printSegment(
            .{ .text = chip, .style = palette.agent_chip },
            .{ .row_offset = 0, .col_offset = chip_col },
        );
        _ = win.printSegment(
            .{ .text = status_text, .style = if (pending) palette.status_busy else palette.status_idle },
            .{ .row_offset = 0, .col_offset = status_col },
        );
    }

    // Separator rule: left quarter in tiger orange, rest in smoke.
    // The coloured prefix echoes the title badge and gives the
    // header some visual weight without dominating the chat scroll.
    if (win.height > 1 and win.width > 0) {
        const accent_cols: u16 = @min(@as(u16, @intCast(win.width)), 18);
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            const style: vaxis.Style = if (col < accent_cols)
                .{ .fg = palette.orange }
            else
                palette.separator;
            _ = win.printSegment(
                .{ .text = "━", .style = style },
                .{ .row_offset = 1, .col_offset = col },
            );
        }
    }
}

/// Return the largest byte count ≤ `max` that ends on a UTF-8
/// codepoint boundary. Continuation bytes (`10xxxxxx`) never start a
/// codepoint, so we walk back from `max` until we find a leading byte.
/// ASCII-only strings return `max` in one pass.
fn safeUtf8Take(bytes: []const u8, max: usize) usize {
    if (max >= bytes.len) return bytes.len;
    if (max == 0) return 0;
    var n = max;
    while (n > 0 and (bytes[n] & 0b1100_0000) == 0b1000_0000) : (n -= 1) {}
    return n;
}

/// Walk `bytes` codepoint by codepoint, accumulating display columns
/// via vaxis's `gwidth` table. Stop just before exceeding `max_cols`.
/// Returns the byte count and the column count consumed.
///
/// This is what you want for terminal layout — `safeUtf8Take` caps on
/// bytes, which for multi-byte chars (emoji, em-dash) overshoots the
/// visible width and causes wrapped-row overlap. Callers should use
/// the `bytes` return for slicing and the `cols` return if they
/// track remaining row space.
fn takeCols(bytes: []const u8, max_cols: usize) struct { bytes: usize, cols: usize } {
    if (max_cols == 0) return .{ .bytes = 0, .cols = 0 };
    var i: usize = 0;
    var cols: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const seq_len: usize = if (b < 0x80)
            1
        else if ((b & 0b1110_0000) == 0b1100_0000)
            2
        else if ((b & 0b1111_0000) == 0b1110_0000)
            3
        else if ((b & 0b1111_1000) == 0b1111_0000)
            4
        else
            1;
        if (i + seq_len > bytes.len) break;
        const w: usize = @intCast(vaxis.gwidth.gwidth(bytes[i .. i + seq_len], .unicode));
        if (cols + w > max_cols) break;
        cols += w;
        i += seq_len;
    }
    return .{ .bytes = i, .cols = cols };
}

/// Sum the total display columns across every byte of `bytes`. Used
/// to compute how many terminal rows a history line will need when
/// word-wrapped to a given column budget.
fn measureCols(bytes: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
}

/// Copy `bytes` into `out`, replacing any byte that is not part of a
/// valid UTF-8 sequence with `?`. This prevents corrupted input (stray
/// escape-sequence bytes, partial sequences from a glitchy terminal,
/// truncated provider chunks) from reaching the renderer and showing
/// as `�`-glyphs in the chat history.
fn appendSanitizedUtf8(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const seq_len: usize = if (b < 0x80)
            1
        else if ((b & 0b1110_0000) == 0b1100_0000)
            2
        else if ((b & 0b1111_0000) == 0b1110_0000)
            3
        else if ((b & 0b1111_1000) == 0b1111_0000)
            4
        else
            0;

        if (seq_len == 0 or i + seq_len > bytes.len) {
            try list.append(allocator, '?');
            i += 1;
            continue;
        }
        if (std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len])) {
            // U+FFFD (encoded as EF BF BD) is the Unicode replacement
            // character. Its presence always means an upstream layer
            // already substituted it for invalid data — emitting it to
            // the terminal produces the black-diamond-question-mark
            // glyph. Drop it silently; nothing legitimate uses it.
            if (seq_len == 3 and bytes[i] == 0xEF and bytes[i + 1] == 0xBF and bytes[i + 2] == 0xBD) {
                i += 3;
                continue;
            }
            try list.appendSlice(allocator, bytes[i .. i + seq_len]);
            i += seq_len;
        } else {
            try list.append(allocator, '?');
            i += 1;
        }
    }
}

fn drawHistory(pane: vaxis.Window, history: []const Line) void {
    // Walk newest-first, rendering upward. Long lines wrap at pane
    // width with a naive byte-based split — good enough for ASCII
    // and passable for UTF-8 text without zero-width combiners.
    var row_cursor: i32 = @as(i32, @intCast(pane.height)) - 1;

    var i: usize = history.len;
    while (i > 0 and row_cursor >= 0) {
        i -= 1;
        const line = history[i];
        // Speaker glyphs — single-cell Unicode only. The previous
        // agent prefix `🐯 ` was a wide emoji (2 display cells) that
        // triggered grapheme-width races on some macOS terminals
        // during streaming redraws — lines got painted partially and
        // looked like empty prefixes. Switched to the `✦` star glyph
        // (1 cell, warm amber in context) so the agent still reads
        // distinctly without the width hazard.
        const prefix = switch (line.role) {
            .user => "❯ ",
            .agent => "✦ ",
            .system => "∙ ",
            .tool => "↻ ",
            // Legacy fallback path (non-vxfw). Banner rows render
            // as bare wordmark text without a glyph prefix; the
            // gradient styling lives only on the vxfw path.
            .banner => "",
        };

        const width: usize = @intCast(pane.width);
        // Prefix width in *display columns*, not bytes. Emoji glyphs
        // (e.g. the agent's 🐯) are 4 bytes but ~2 display cells, so
        // using \`prefix.len\` here would over-estimate by 2 cells
        // per emoji prefix and throw every wrap calculation off.
        const prefix_cols: usize = measureCols(prefix);
        const avail = if (width > prefix_cols) width - prefix_cols else 1;

        // Rows needed is driven by *display columns* and counts
        // embedded newlines as explicit row breaks. Each line
        // segment between newlines contributes ceil(cols / avail)
        // rows. Without this, markdown lists / tool output
        // containing \\n get painted with the newline interpreted
        // mid-row, scrambling the display.
        var rows_needed: usize = 0;
        var seg_it = std.mem.splitScalar(u8, line.text.items, '\n');
        while (seg_it.next()) |seg| {
            const seg_cols = measureCols(seg);
            const seg_rows: usize = if (seg_cols == 0) 1 else (seg_cols + avail - 1) / avail;
            rows_needed += seg_rows;
        }
        if (rows_needed == 0) rows_needed = 1;
        if (rows_needed > 32) rows_needed = 32;

        var remaining = line.text.items;
        var start_row = row_cursor - @as(i32, @intCast(rows_needed - 1));
        if (start_row < 0) {
            const drop = @as(usize, @intCast(-start_row));
            if (drop >= rows_needed) {
                row_cursor -= @intCast(rows_needed);
                continue;
            }
            // Skip `drop` rows worth of columns off the front of the
            // line. Walk by columns, not bytes, so multi-byte chars
            // don't trigger the same sizing bug here.
            var cols_to_skip: usize = drop * avail;
            while (cols_to_skip > 0 and remaining.len > 0) {
                const taken = takeCols(remaining, cols_to_skip);
                if (taken.bytes == 0) break;
                remaining = remaining[taken.bytes..];
                cols_to_skip -= taken.cols;
                if (taken.cols == 0) break;
            }
            rows_needed -= drop;
            start_row = 0;
        }

        const base_style: vaxis.Style = switch (line.role) {
            .user => palette.user,
            .agent => palette.agent,
            .system => palette.system,
            .tool => palette.tool,
            // Legacy path: banner rows fall back to the system tint;
            // the wordmark gradient is vxfw-only.
            .banner => palette.system,
        };

        var row = start_row;
        _ = pane.printSegment(
            .{ .text = prefix, .style = base_style },
            .{ .row_offset = @intCast(row), .col_offset = 0 },
        );

        // Track the byte offset of `remaining[0]` back into the full
        // line.text buffer so we can look up which markdown span
        // covers each byte as we paint. `drop` accounted for rows
        // that fell off the top of the pane when row_cursor < 0.
        const total_len = line.text.items.len;
        const span_offset_start: usize = total_len - remaining.len;

        var col_offset: usize = prefix_cols;
        while (remaining.len > 0 and row < pane.height) {
            // Hard-wrap on embedded newlines: if the next segment
            // contains `\n`, stop at it, paint what's before, and
            // move the row cursor forward. Without this, we'd paint
            // `abc\ndef` as one segment and the terminal would
            // interpret the `\n` mid-row, jumping the cursor and
            // scrambling subsequent rows.
            const nl_pos: ?usize = std.mem.indexOfScalar(u8, remaining, '\n');
            const limit = if (nl_pos) |p| p else remaining.len;
            const slice = remaining[0..limit];

            // Then soft-wrap on display columns within the limit.
            const taken = takeCols(slice, avail);
            const take = if (taken.bytes == 0) safeUtf8Take(slice, 1) else taken.bytes;
            paintRow(
                pane,
                @intCast(row),
                @intCast(col_offset),
                remaining[0..take],
                span_offset_start + (remaining.ptr - line.text.items.ptr),
                base_style,
                line.spans,
            );
            remaining = remaining[take..];
            // Consume the newline itself if we stopped at one and
            // didn't also consume all the visible bytes on that row.
            if (remaining.len > 0 and remaining[0] == '\n') {
                remaining = remaining[1..];
            }
            row += 1;
            col_offset = prefix_cols;
        }

        row_cursor -= @intCast(rows_needed);
    }
}

/// Paint one row of wrapped text, applying per-byte markdown span
/// styles. Walks the slice in runs of constant style and emits one
/// `printSegment` per run.
fn paintRow(
    pane: vaxis.Window,
    row: u16,
    col_offset: u16,
    bytes: []const u8,
    bytes_start_in_line: usize,
    base_style: vaxis.Style,
    spans: ?[]md.Span,
) void {
    if (spans == null or spans.?.len == 0) {
        _ = pane.printSegment(
            .{ .text = bytes, .style = base_style },
            .{ .row_offset = row, .col_offset = col_offset },
        );
        return;
    }
    const all_spans = spans.?;

    var i: usize = 0;
    var col = col_offset;
    while (i < bytes.len) {
        const abs = bytes_start_in_line + i;
        const style = pickStyle(abs, base_style, all_spans);

        // Extend `j` while the style at byte `j` matches `style`.
        var j = i + 1;
        while (j < bytes.len and styleEql(pickStyle(bytes_start_in_line + j, base_style, all_spans), style)) : (j += 1) {}

        const slice = bytes[i..j];
        _ = pane.printSegment(
            .{ .text = slice, .style = style },
            .{ .row_offset = row, .col_offset = col },
        );
        // Advance column by *display width*, not byte count — a
        // styled span containing emoji used to over-advance and
        // push following spans off the right edge of the row.
        col += @intCast(measureCols(slice));
        i = j;
    }
}

/// Pick the style for byte `abs` in the full line: the innermost
/// covering span's style overlaid on `base`, or `base` alone.
fn pickStyle(abs: usize, base: vaxis.Style, spans: []md.Span) vaxis.Style {
    var s = base;
    for (spans) |sp| {
        if (abs >= sp.start and abs < sp.start + sp.len) {
            s = palette.mdStyle(s, sp.style);
        }
    }
    return s;
}

fn styleEql(a: vaxis.Style, b: vaxis.Style) bool {
    return std.meta.eql(a, b);
}

fn drawPicker(
    win: vaxis.Window,
    agents: []const []const u8,
    cursor: usize,
) void {
    const max_items: usize = 12;
    const visible: usize = @min(agents.len, max_items);
    const panel_h: u16 = @intCast(visible + 2);

    var longest: usize = 0;
    for (agents) |name| if (name.len > longest) {
        longest = name.len;
    };
    const desired = longest + 6;
    const min_w: usize = 24;
    const max_w: usize = @intCast(win.width);
    const panel_w: u16 = @intCast(std.math.clamp(desired, min_w, if (max_w > 4) max_w - 4 else max_w));

    if (panel_h + 2 > win.height or panel_w + 2 > win.width) return;

    const x: i17 = @intCast(@divTrunc(@as(i32, @intCast(win.width)) - @as(i32, panel_w), 2));
    const y: i17 = @intCast(@divTrunc(@as(i32, @intCast(win.height)) - @as(i32, panel_h), 2));

    const panel = win.child(.{
        .x_off = x,
        .y_off = y,
        .width = panel_w,
        .height = panel_h,
        .border = .{ .where = .all, .style = palette.picker_border },
    });

    _ = panel.printSegment(
        .{ .text = " select agent ", .style = palette.picker_border },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    const list_w: u16 = if (panel.width > 2) panel.width - 2 else 0;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const name = agents[i];
        const style = if (i == cursor) palette.picker_item_selected else palette.picker_item;
        var line_buf: [256]u8 = undefined;
        const marker: []const u8 = if (i == cursor) "➤ " else "  ";
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ marker, name }) catch name;
        const take = @min(line.len, list_w);
        _ = panel.printSegment(
            .{ .text = line[0..take], .style = style },
            .{ .row_offset = @intCast(i + 1), .col_offset = 1 },
        );
        if (take < list_w) {
            var pad_buf: [256]u8 = undefined;
            const pad_len = @min(list_w - take, pad_buf.len);
            @memset(pad_buf[0..pad_len], ' ');
            _ = panel.printSegment(
                .{ .text = pad_buf[0..pad_len], .style = style },
                .{ .row_offset = @intCast(i + 1), .col_offset = @intCast(1 + take) },
            );
        }
    }
}

/// Count codepoints in a UTF-8 slice. Good enough for the header
/// layout math — most glyphs we draw are single-cell.
fn visualWidth(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const seq_len: usize = if (b < 0x80) 1 else if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        i += seq_len;
        count += 1;
    }
    return count;
}

/// In-memory roster of agents. Names are owned slices; the struct
/// frees them on `deinit`.
const AgentList = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) AgentList {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *AgentList) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
    }

    fn count(self: *const AgentList) usize {
        return self.names.items.len;
    }

    fn items(self: *const AgentList) []const []const u8 {
        return @ptrCast(self.names.items);
    }

    fn name(self: *const AgentList, idx: usize) []const u8 {
        return self.names.items[idx];
    }

    fn append(self: *AgentList, n: []const u8) !void {
        const copy = try self.allocator.dupe(u8, n);
        errdefer self.allocator.free(copy);
        try self.names.append(self.allocator, copy);
    }

    fn findOrAppend(self: *AgentList, n: []const u8) !usize {
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, n)) return i;
        }
        try self.append(n);
        return self.names.items.len - 1;
    }

    /// Populate from `<home>/.tigerclaw/agents/`. Empty or missing
    /// home short-circuits silently — the caller still appends the
    /// default agent so the TUI is usable.
    fn loadFromDisk(self: *AgentList, io: std.Io, home: []const u8) !void {
        if (home.len == 0) return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.tigerclaw/agents", .{home}) catch return;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            try self.append(entry.name);
        }
        // Sort so agent order is deterministic across launches —
        // the scan order from the filesystem isn't stable.
        std.mem.sort([]u8, self.names.items, {}, lessThanName);
    }
};

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// State handed to the worker thread. The worker owns `message` and
/// frees it on exit; the context struct itself is freed last.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *EventLoop,
    /// Borrowed reference to the TUI's in-process runner. Shared
    /// across every worker turn on the same agent; swapped out on
    /// agent switch (see `reloadRunner`). Not owned here.
    runner: *harness.AgentRunner,
    session_id: []const u8,
    message: []u8,
};

fn workerMain(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.message);
        ctx.allocator.destroy(ctx);
    }

    runTurn(ctx) catch |err| {
        const msg = if (err == error.Interrupted or err == error.Cancelled)
            ctx.allocator.dupe(u8, "∙ turn cancelled")
        else
            std.fmt.allocPrint(
                ctx.allocator,
                "! turn failed: {s}",
                .{@errorName(err)},
            );
        const owned_msg = msg catch {
            ctx.loop.postEvent(.turn_done);
            return;
        };
        ctx.loop.postEvent(.{ .turn_error = owned_msg });
        return;
    };
    ctx.loop.postEvent(.turn_done);
}

fn runTurn(ctx: *WorkerCtx) !void {
    // No gateway round-trip: call the runner directly and let the
    // sinks post events onto the vaxis loop as the provider streams.
    // The runner still fires `stream_sink` per text delta and
    // `tool_event_sink` on each tool-dispatch boundary.
    const result = ctx.runner.run(.{
        .session_id = ctx.session_id,
        .input = ctx.message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = @ptrCast(ctx),
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = @ptrCast(ctx),
    }) catch |err| {
        const name = @errorName(err);
        const msg = try std.fmt.allocPrint(ctx.allocator, "runner: {s}", .{name});
        ctx.loop.postEvent(.{ .turn_error = msg });
        return;
    };
    _ = result;
}

/// Sink adapter: each text fragment from the provider becomes one
/// `turn_chunk` event on the vaxis loop. The fragment is duped
/// because the runner borrows it across the callback only.
fn chunkSink(sink_ctx: ?*anyopaque, fragment: []const u8) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    const owned = ctx.allocator.dupe(u8, fragment) catch return;
    ctx.loop.postEvent(.{ .turn_chunk = owned });
}

/// Sink adapter for tool-dispatch boundaries. Each variant of the
/// `ToolEvent` union maps to a vaxis event the main loop frees after
/// handling. `progress` events are dropped here today (phase 9 will
/// route them into a streaming widget); the runner still fires them
/// for any consumer that wants to.
fn toolEventSink(
    sink_ctx: ?*anyopaque,
    event: harness.agent_runner.ToolEvent,
) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(sink_ctx.?));
    switch (event) {
        .started => |s| {
            const id_owned = ctx.allocator.dupe(u8, s.id) catch return;
            errdefer ctx.allocator.free(id_owned);
            const name_owned = ctx.allocator.dupe(u8, s.name) catch return;
            errdefer ctx.allocator.free(name_owned);
            // Dupe even when empty so the consumer can free
            // unconditionally; allocator.dupe of "" returns a
            // zero-length slice from the allocator and freeing it
            // is a no-op on most allocators but well-defined.
            const summary_owned = ctx.allocator.dupe(u8, s.args_summary) catch return;
            ctx.loop.postEvent(.{ .turn_tool_start = .{
                .id = id_owned,
                .name = name_owned,
                .args_summary = summary_owned,
            } });
        },
        .progress => {
            // Phase 9 hook. Today the streamed bash chunks are
            // visible in the final tool_result block once dispatch
            // completes, so dropping in-flight chunks loses nothing.
        },
        .finished => |f| {
            const id_owned = ctx.allocator.dupe(u8, f.id) catch return;
            errdefer ctx.allocator.free(id_owned);
            const name_owned = ctx.allocator.dupe(u8, f.name) catch return;
            errdefer ctx.allocator.free(name_owned);
            const preview = tool_preview.render(ctx.allocator, f.name, f.kind) catch
                ctx.allocator.dupe(u8, f.kind.flatText()) catch return;
            ctx.loop.postEvent(.{ .turn_tool_done = .{
                .id = id_owned,
                .name = name_owned,
                .output = preview,
            } });
        },
    }
}

const TickerCtx = struct {
    io: std.Io,
    loop: *EventLoop,
    stop: *std.atomic.Value(bool),
};

fn tickerMain(ctx: TickerCtx) void {
    // 80ms cadence — fast enough that the spinner feels alive,
    // slow enough that the vaxis queue doesn't saturate.
    const interval_ns: u64 = 80 * std.time.ns_per_ms;
    while (!ctx.stop.load(.acquire)) {
        std.Io.sleep(ctx.io, std.Io.Duration.fromNanoseconds(interval_ns), .awake) catch {};
        if (ctx.stop.load(.acquire)) break;
        // tryPostEvent so a saturated queue drops ticks instead of
        // blocking the ticker on a stalled UI.
        _ = ctx.loop.tryPostEvent(.tick);
    }
}

/// Read `~/.tigerclaw/config.json` and return the
/// `auto_dispatch_max_calls` field if present and in-range. Anything
/// short of "well-formed JSON object with that key as a small unsigned
/// integer" returns null — the caller falls back to the built-in
/// default. Best-effort: missing files, parse errors, IO errors all
/// collapse to null. We do not surface a system row for the failure
/// path because the TUI hasn't booted yet at this point.
fn readAutoDispatchMaxCalls(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ?u8 {
    if (home.len == 0) return null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.tigerclaw/config.json", .{home}) catch return null;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var raw_buf: [4096]u8 = undefined;
    var io_reader_buf: [256]u8 = undefined;
    var reader = file.reader(io, &io_reader_buf);
    const n = reader.interface.readSliceShort(&raw_buf) catch return null;
    if (n == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_buf[0..n], .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("auto_dispatch_max_calls") orelse return null;
    const n_i64 = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (n_i64 < 1 or n_i64 > 64) return null;
    return @intCast(n_i64);
}

/// Read the `model` field from `<home>/.tigerclaw/agents/<agent>/agent.json`.
/// Returns an owned slice on success, null when the manifest is missing,
/// unreadable, malformed, or doesn't carry a `model` key. The status bar
/// uses this so it can show the actual provider model (e.g.
/// `claude-haiku-4-5-20251001`) — `modelMaxContext` then matches that
/// against the known-window table to populate the context bar's max.
fn readActiveAgentModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    agent_name: []const u8,
) !?[]u8 {
    if (home.len == 0 or agent_name.len == 0) return null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/.tigerclaw/agents/{s}/agent.json",
        .{ home, agent_name },
    ) catch return null;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var raw_buf: [4096]u8 = undefined;
    var io_reader_buf: [256]u8 = undefined;
    var reader = file.reader(io, &io_reader_buf);
    const n = reader.interface.readSliceShort(&raw_buf) catch return null;
    if (n == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_buf[0..n], .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("model") orelse return null;
    const s = switch (v) {
        .string => |str| str,
        else => return null,
    };
    return try allocator.dupe(u8, s);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "safeUtf8Take: ASCII is truncated at the requested byte count" {
    try testing.expectEqual(@as(usize, 5), safeUtf8Take("hello world", 5));
    try testing.expectEqual(@as(usize, 11), safeUtf8Take("hello world", 100));
    try testing.expectEqual(@as(usize, 0), safeUtf8Take("x", 0));
}

test "safeUtf8Take: never splits a multi-byte codepoint" {
    // "·" is U+00B7, encoded as 0xC2 0xB7 (2 bytes). A naive byte
    // truncation at max=1 would leave a dangling 0xC2 — the helper
    // must back up to the start of the codepoint instead.
    const s = "a·b";
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 1)); // "a"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 2)); // back up: "a"
    try testing.expectEqual(@as(usize, 3), safeUtf8Take(s, 3)); // "a·"
    try testing.expectEqual(@as(usize, 4), safeUtf8Take(s, 4)); // "a·b"
}

test "appendSanitizedUtf8: replaces stray lead byte with ?" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // `z` + stray 0xE2 (lead byte with no continuation) + `y` — the
    // real-world symptom the sanitizer exists to stop.
    try appendSanitizedUtf8(&buf, testing.allocator, "z\xE2y");
    try testing.expectEqualStrings("z?y", buf.items);
}

test "appendSanitizedUtf8: preserves valid multi-byte sequences" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendSanitizedUtf8(&buf, testing.allocator, "Hey \xF0\x9F\x91\x8B world");
    try testing.expectEqualStrings("Hey \xF0\x9F\x91\x8B world", buf.items);
}

test "appendSanitizedUtf8: drops U+FFFD replacement characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // EF BF BD is U+FFFD — upstream already substituted this for bad
    // input, so we drop it rather than forwarding the black-diamond
    // glyph to the terminal.
    try appendSanitizedUtf8(&buf, testing.allocator, "ok\xEF\xBF\xBDS");
    try testing.expectEqualStrings("okS", buf.items);
}

test "appendSanitizedUtf8: replaces truncated trailing lead byte" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Trailing 0xE2 with nothing after it — classic chunk-cut scenario.
    try appendSanitizedUtf8(&buf, testing.allocator, "ok\xE2");
    try testing.expectEqualStrings("ok?", buf.items);
}

test "safeUtf8Take: backs up through a 3-byte character" {
    // "世" is U+4E16, encoded as 0xE4 0xB8 0x96 (3 bytes).
    const s = "x世y";
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 1)); // "x"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 2)); // back up: "x"
    try testing.expectEqual(@as(usize, 1), safeUtf8Take(s, 3)); // back up: "x"
    try testing.expectEqual(@as(usize, 4), safeUtf8Take(s, 4)); // "x世"
    try testing.expectEqual(@as(usize, 5), safeUtf8Take(s, 5)); // "x世y"
}

test "makeLine/appendLine: round-trips text into owned storage" {
    var history: std.ArrayList(Line) = .empty;
    defer {
        for (history.items) |*l| l.text.deinit(testing.allocator);
        history.deinit(testing.allocator);
    }

    try appendLine(&history, testing.allocator, .user, "hi");
    try appendLine(&history, testing.allocator, .agent, "hello");

    try testing.expectEqual(@as(usize, 2), history.items.len);
    try testing.expectEqualStrings("hi", history.items[0].text.items);
    try testing.expectEqualStrings("hello", history.items[1].text.items);
}

test "AgentList.findOrAppend: dedupes and returns stable indexes" {
    var list = AgentList.init(testing.allocator);
    defer list.deinit();

    const a = try list.findOrAppend("tiger");
    const b = try list.findOrAppend("claw");
    const c = try list.findOrAppend("tiger");
    try testing.expectEqual(@as(usize, 0), a);
    try testing.expectEqual(@as(usize, 1), b);
    try testing.expectEqual(@as(usize, 0), c);
    try testing.expectEqual(@as(usize, 2), list.count());
}

test "visualWidth: counts codepoints, not bytes" {
    try testing.expectEqual(@as(usize, 3), visualWidth("abc"));
    // Single-cell box-drawing glyph "─" is 3 bytes in UTF-8.
    try testing.expectEqual(@as(usize, 1), visualWidth("─"));
    try testing.expectEqual(@as(usize, 5), visualWidth("a─b─c"));
}
