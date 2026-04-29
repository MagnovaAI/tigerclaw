//! `tigerclaw setup` — interactive first-run configuration wizard.
//!
//! Walks the user through three sections (gateway, provider, agent),
//! validates the resulting `Settings`, writes it atomically, then
//! prints a summary. Supports `--non-interactive` for scripted installs
//! that want defaults written without prompts.

const std = @import("std");
const managed_path = @import("../../settings/managed_path.zig");
const schema = @import("../../settings/schema.zig");
const validation = @import("../../settings/validation.zig");
const writer_mod = @import("../../settings/writer.zig");

pub const Args = struct {
    non_interactive: bool = false,
    /// Optional explicit config path (mirrors --config flag in other cmds).
    config_path: ?[]const u8 = null,
};

pub const RunError = error{
    /// No HOME/XDG/TIGERCLAW_CONFIG found — cannot determine config path.
    NoConfigPath,
    /// Resulting settings failed validation.
    InvalidConfig,
    /// Could not write the config file.
    WriteFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// TTY prompt helpers
// ---------------------------------------------------------------------------

/// Print `label` then read a line from `stdin`. If the user presses Enter
/// without typing anything, `default` is returned (caller-owned slice from
/// `arena`). Returned slice is always arena-allocated.
fn prompt(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    label: []const u8,
    default: []const u8,
) ![]const u8 {
    if (default.len > 0) {
        try w.print("{s} [{s}]: ", .{ label, default });
    } else {
        try w.print("{s}: ", .{label});
    }

    // Read until newline, up to 4 KiB.
    var buf: [4096]u8 = undefined;
    const n = r.readLine(&buf) catch 0;
    const line = std.mem.trimRight(u8, buf[0..n], "\r\n");

    if (line.len == 0) {
        return arena.dupe(u8, default);
    }
    return arena.dupe(u8, line);
}

/// Like `prompt` but suppresses terminal echo while the user types, then
/// restores it. Useful for tokens/passwords. Falls back gracefully when not
/// on a real TTY.
fn promptSecret(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    label: []const u8,
) ![]const u8 {
    try w.print("{s} (hidden): ", .{label});

    // Attempt to disable echo. Best-effort — ignore failures on non-TTYs.
    var old_termios: std.posix.termios = undefined;
    const is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    if (is_tty) {
        if (std.posix.tcgetattr(std.posix.STDIN_FILENO, &old_termios)) |_| {
            var raw = old_termios;
            raw.lflag.ECHO = false;
            _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {};
        } else |_| {}
    }

    var buf: [4096]u8 = undefined;
    const n = r.readLine(&buf) catch 0;
    const line = std.mem.trimRight(u8, buf[0..n], "\r\n");

    // Restore echo and print a newline (echo suppression swallowed it).
    if (is_tty) {
        _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, old_termios) catch {};
        try w.writeAll("\n");
    }

    return arena.dupe(u8, line);
}

/// Prompt for an unsigned 32-bit integer. Reprompts on bad input.
fn promptU32(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    label: []const u8,
    default: u32,
) !u32 {
    var buf: [64]u8 = undefined;
    while (true) {
        try w.print("{s} [{d}]: ", .{ label, default });
        const n = r.readLine(&buf) catch 0;
        const line = std.mem.trimRight(u8, buf[0..n], "\r\n");
        if (line.len == 0) return default;
        const v = std.fmt.parseInt(u32, line, 10) catch {
            try w.print("  (expected a positive integer, got '{s}')\n", .{line});
            continue;
        };
        if (v == 0) {
            try w.writeAll("  (value must be > 0)\n");
            _ = arena; // suppress unused warning in this branch
            continue;
        }
        return v;
    }
}

// ---------------------------------------------------------------------------
// Section helpers
// ---------------------------------------------------------------------------

fn sectionGateway(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    existing: schema.Gateway,
) !schema.Gateway {
    try w.writeAll("\n=== Gateway ===\n");
    try w.writeAll("Leave URL blank to run in local mode (no remote gateway).\n");

    const url = try prompt(arena, w, r, "Gateway URL", existing.url);

    // Only ask for a token when a URL was supplied.
    const token: []const u8 = if (url.len > 0)
        try promptSecret(arena, w, r, "Gateway token")
    else
        "";

    return .{ .url = url, .token = token };
}

fn sectionProvider(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    existing: schema.Provider,
) !schema.Provider {
    try w.writeAll("\n=== Provider ===\n");
    const name = try prompt(arena, w, r, "Provider name", existing.name);
    const model = try prompt(arena, w, r, "Model", existing.model);
    return .{ .name = name, .model = model };
}

fn sectionAgent(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    existing: schema.AgentConfig,
) !schema.AgentConfig {
    try w.writeAll("\n=== Agent ===\n");
    const timeout_secs = try promptU32(arena, w, r, "Timeout (seconds)", existing.timeout_secs);
    const max_retries = try promptU32(arena, w, r, "Max retries", existing.max_retries);
    return .{ .timeout_secs = timeout_secs, .max_retries = max_retries };
}

// ---------------------------------------------------------------------------
// Existing config loader — best-effort, returns defaults on any failure
// ---------------------------------------------------------------------------

fn loadExisting(io: std.Io, arena: std.mem.Allocator, path: []const u8) schema.Settings {
    // Attempt to open and read the file. Any failure → return defaults.
    var dir = Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path) orelse ".", .{}) catch
        return schema.defaultSettings();
    defer dir.close(io);

    const filename = std.fs.path.basename(path);
    var buf: [128 * 1024]u8 = undefined;
    const bytes = dir.readFile(io, filename, &buf) catch
        return schema.defaultSettings();

    const parsed = std.json.parseFromSlice(
        schema.Settings,
        arena,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return schema.defaultSettings();
    // Intentionally not deiniting — we're using the arena.
    return parsed.value;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    args: Args,
    environ: anytype,
) RunError!void {
    // Resolve config path. Honour explicit flag first, then env cascade.
    const resolved = managed_path.resolve(arena, .{
        .flag = args.config_path,
        .env_config = environ.get("TIGERCLAW_CONFIG"),
        .env_xdg = environ.get("XDG_CONFIG_HOME"),
        .env_home = environ.get("HOME"),
    }) catch |err| switch (err) {
        error.NoCandidate => return error.NoConfigPath,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // resolved.path is arena-allocated; no manual deinit needed.

    // Load existing config for defaults (best-effort).
    const existing = loadExisting(io, arena, resolved.path);

    var settings: schema.Settings = existing;

    if (!args.non_interactive) {
        settings.gateway = sectionGateway(arena, w, r, existing.gateway) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        settings.provider = sectionProvider(arena, w, r, existing.provider) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        settings.agent = sectionAgent(arena, w, r, existing.agent) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // Validate before touching the FS.
    var issues: std.array_list.Aligned(validation.Issue, null) = .empty;
    issues.ensureTotalCapacity(arena, 16) catch return error.OutOfMemory;
    // issues is arena-backed; no manual deinit needed.

    validation.validate(arena, settings, &issues) catch |err| switch (err) {
        error.InvalidSettings => {
            w.writeAll("\nConfiguration is invalid:\n") catch {};
            for (issues.items) |issue| {
                w.print("  {s}: {s}\n", .{ issue.field, issue.reason }) catch {};
            }
            return error.InvalidConfig;
        },
    };

    // Write atomically.
    writer_mod.writeToPath(io, arena, settings, resolved.path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MkdirFailed, error.WriteFailed => return error.WriteFailed,
    };

    // Print summary.
    w.print("\nConfiguration written to: {s}\n", .{resolved.path}) catch {};
    w.writeAll("\nSummary:\n") catch {};
    w.print("  gateway.url        {s}\n", .{if (settings.gateway.url.len == 0) "<local>" else settings.gateway.url}) catch {};
    w.print("  provider.name      {s}\n", .{settings.provider.name}) catch {};
    w.print("  provider.model     {s}\n", .{settings.provider.model}) catch {};
    w.print("  agent.timeout_secs {d}\n", .{settings.agent.timeout_secs}) catch {};
    w.print("  agent.max_retries  {d}\n", .{settings.agent.max_retries}) catch {};
    w.writeAll("\nSetup complete.\n") catch {};
}
