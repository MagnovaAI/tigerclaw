//! Workspace-wide grep. Prefers `rg` (ripgrep) when available, falls
//! back to an in-process literal-substring scanner.
//!
//! Output mirrors `rg --no-heading -n` so frontier-coder models that
//! were trained on rg's format can read it without translation:
//!   path:lineno:line content
//!
//! `output_mode = files_with_matches` returns one path per line.
//! `output_mode = count` returns `path:N` per file.

const std = @import("std");
const tool_bash = @import("tool_bash.zig");
const tool_glob = @import("tool_glob.zig");

pub const GrepError = error{
    InvalidPath,
    InvalidPattern,
    PathEscapesWorkspace,
    OpenFailed,
    SpawnFailed,
} || std.mem.Allocator.Error;

pub const OutputMode = enum { content, files_with_matches, count };

pub const GrepOptions = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    output_mode: OutputMode = .content,
    case_insensitive: bool = false,
    /// Lines of context before each match (rg fast-path only).
    context_before: u32 = 0,
    /// Lines of context after each match (rg fast-path only).
    context_after: u32 = 0,
};

pub const GrepResult = struct {
    /// Already formatted output, owned.
    formatted: []u8,
    file_count: u32,
    match_count: u32,
    truncated: bool,

    pub fn deinit(self: GrepResult, allocator: std.mem.Allocator) void {
        allocator.free(self.formatted);
    }
};

/// 100 matches across all files; rg passes `-m N` per file, in-process
/// counts globally.
pub const MAX_MATCHES: usize = 100;

// ---------------------------------------------------------------------------
// rg detection — done once per process, cached.

var rg_check_done: bool = false;
var rg_available: bool = false;

fn detectRg(allocator: std.mem.Allocator, io: std.Io) bool {
    if (rg_check_done) return rg_available;
    const result = tool_bash.run(allocator, io, .{
        .command = "command -v rg",
        .cwd = ".",
        .timeout_ms = 1_000,
    }) catch {
        rg_available = false;
        rg_check_done = true;
        return false;
    };
    defer result.deinit(allocator);
    rg_available = result.exit_code == 0;
    rg_check_done = true;
    return rg_available;
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    opts: GrepOptions,
) GrepError!GrepResult {
    if (opts.pattern.len == 0) return error.InvalidPattern;

    if (detectRg(allocator, io)) {
        return runViaRipgrep(allocator, io, workspace_root, opts) catch |e| switch (e) {
            error.SpawnFailed, error.InvalidPattern => runInProcess(allocator, io, workspace_root, opts),
            else => |err| return err,
        };
    }
    return runInProcess(allocator, io, workspace_root, opts);
}

// ---------------------------------------------------------------------------
// rg fast-path

fn runViaRipgrep(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    opts: GrepOptions,
) GrepError!GrepResult {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(allocator);

    try cmd.appendSlice(allocator, "rg --no-heading -n");
    if (opts.case_insensitive) try cmd.appendSlice(allocator, " -i");
    if (opts.context_before > 0) {
        const n = try std.fmt.allocPrint(allocator, " -B {d}", .{opts.context_before});
        defer allocator.free(n);
        try cmd.appendSlice(allocator, n);
    }
    if (opts.context_after > 0) {
        const n = try std.fmt.allocPrint(allocator, " -A {d}", .{opts.context_after});
        defer allocator.free(n);
        try cmd.appendSlice(allocator, n);
    }
    switch (opts.output_mode) {
        .content => {},
        .files_with_matches => try cmd.appendSlice(allocator, " -l"),
        .count => try cmd.appendSlice(allocator, " -c"),
    }
    if (opts.glob) |g| {
        try cmd.appendSlice(allocator, " --glob ");
        try shellQuote(&cmd, allocator, g);
    }
    try cmd.append(allocator, ' ');
    try shellQuote(&cmd, allocator, opts.pattern);
    if (opts.path) |p| {
        try cmd.append(allocator, ' ');
        try shellQuote(&cmd, allocator, p);
    }

    const result = tool_bash.run(allocator, io, .{
        .command = cmd.items,
        .cwd = workspace_root,
        .timeout_ms = 30_000,
    }) catch return error.SpawnFailed;
    defer result.deinit(allocator);

    return parseRgOutput(allocator, result.stdout, opts.output_mode);
}

pub fn shellQuote(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

pub fn parseRgOutput(
    allocator: std.mem.Allocator,
    raw: []const u8,
    mode: OutputMode,
) !GrepResult {
    // Re-emit verbatim for the model, but tally counts and truncate.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var seen_files: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_files.deinit(allocator);

    var match_count: u32 = 0;
    var truncated = false;

    var line_iter = std.mem.splitScalar(u8, raw, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        // Track distinct file count for the formatted summary.
        if (mode == .content) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon1| {
                const path_part = line[0..colon1];
                if (!seen_files.contains(path_part)) {
                    try seen_files.put(allocator, path_part, {});
                }
            }
            match_count += 1;
        } else if (mode == .files_with_matches) {
            if (!seen_files.contains(line)) {
                try seen_files.put(allocator, line, {});
            }
            match_count += 1;
        } else { // count
            match_count += 1;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon1| {
                const path_part = line[0..colon1];
                if (!seen_files.contains(path_part)) {
                    try seen_files.put(allocator, path_part, {});
                }
            }
        }

        if (match_count > MAX_MATCHES) {
            truncated = true;
            break;
        }

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return .{
        .formatted = try out.toOwnedSlice(allocator),
        .file_count = @intCast(seen_files.count()),
        .match_count = match_count,
        .truncated = truncated,
    };
}

// ---------------------------------------------------------------------------
// In-process fallback. Literal substring only — keeps the
// implementation deterministic across Zig std versions.

fn runInProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    opts: GrepOptions,
) GrepError!GrepResult {
    const search_root = opts.path orelse "";

    // Reuse glob's walker so the same ignore-dir set is honored.
    var root_dir = openRoot(io, workspace_root, search_root) catch return error.OpenFailed;
    defer root_dir.close(io);

    var walker = root_dir.walkSelectively(allocator) catch return error.OpenFailed;
    defer walker.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var seen_files: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen_files.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        seen_files.deinit(allocator);
    }

    var match_count: u32 = 0;
    var truncated = false;
    var per_file_count: u32 = 0;

    while (true) {
        const maybe = walker.next(io) catch break;
        const entry = maybe orelse break;

        if (entry.kind == .directory) {
            if (tool_glob.isIgnoredDir(entry.basename)) continue;
            if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
            walker.enter(io, entry) catch continue;
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const rel_path = entry.path; // valid until next next()

        if (opts.glob) |g| {
            if (!tool_glob.matchFullPath(g, rel_path)) continue;
        }

        var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        if (stat.size == 0 or stat.size > 1024 * 1024) continue; // skip empty + huge
        const content = readAll(allocator, io, file, stat.size) catch continue;
        defer allocator.free(content);

        per_file_count = 0;
        var lineno: u32 = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len) : (i += 1) {
            const at_eol = i == content.len or content[i] == '\n';
            if (!at_eol) continue;
            lineno += 1;
            const line = content[line_start..i];
            line_start = i + 1;

            if (containsCi(line, opts.pattern, opts.case_insensitive)) {
                per_file_count += 1;
                if (opts.output_mode == .content) {
                    const rendered = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ rel_path, lineno, line });
                    defer allocator.free(rendered);
                    try out.appendSlice(allocator, rendered);
                    match_count += 1;
                    if (match_count >= MAX_MATCHES) {
                        truncated = true;
                        break;
                    }
                }
            }
        }

        if (per_file_count > 0) {
            const rel_owned = try allocator.dupe(u8, rel_path);
            const gop = try seen_files.getOrPut(allocator, rel_owned);
            if (gop.found_existing) allocator.free(rel_owned);

            switch (opts.output_mode) {
                .content => {}, // already emitted line-by-line
                .files_with_matches => {
                    if (!gop.found_existing) {
                        try out.appendSlice(allocator, rel_path);
                        try out.append(allocator, '\n');
                        match_count += 1;
                    }
                },
                .count => {
                    const rendered = try std.fmt.allocPrint(allocator, "{s}:{d}\n", .{ rel_path, per_file_count });
                    defer allocator.free(rendered);
                    try out.appendSlice(allocator, rendered);
                    match_count += per_file_count;
                },
            }
        }
        if (truncated) break;
    }

    return .{
        .formatted = try out.toOwnedSlice(allocator),
        .file_count = @intCast(seen_files.count()),
        .match_count = match_count,
        .truncated = truncated,
    };
}

fn openRoot(io: std.Io, workspace_root: []const u8, sub: []const u8) !std.Io.Dir {
    if (workspace_root.len == 0 and sub.len == 0) {
        return std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    }
    if (workspace_root.len == 0) {
        return std.Io.Dir.cwd().openDir(io, sub, .{ .iterate = true });
    }
    if (sub.len == 0 or std.mem.eql(u8, sub, ".")) {
        return std.Io.Dir.cwd().openDir(io, workspace_root, .{ .iterate = true });
    }
    var root = try std.Io.Dir.cwd().openDir(io, workspace_root, .{});
    defer root.close(io);
    return root.openDir(io, sub, .{ .iterate = true });
}

fn readAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    size: u64,
) ![]u8 {
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    var off: u64 = 0;
    while (off < size) {
        const n = try file.readPositionalAll(io, buf[@intCast(off)..], off);
        if (n == 0) break;
        off += n;
    }
    return buf[0..@intCast(off)];
}

fn containsCi(haystack: []const u8, needle: []const u8, case_insensitive: bool) bool {
    if (!case_insensitive) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "shellQuote: escapes single quotes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try shellQuote(&buf, testing.allocator, "it's");
    try testing.expectEqualStrings("'it'\\''s'", buf.items);
}

test "shellQuote: plain text wrapped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try shellQuote(&buf, testing.allocator, "foo bar");
    try testing.expectEqualStrings("'foo bar'", buf.items);
}

test "parseRgOutput: standard content mode counts files and matches" {
    const raw =
        "src/main.zig:42:    const x = foo();\n" ++
        "src/main.zig:43:    return x.bar();\n" ++
        "src/util.zig:127:fn foo() !u32 {\n";
    const r = try parseRgOutput(testing.allocator, raw, .content);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), r.file_count);
    try testing.expectEqual(@as(u32, 3), r.match_count);
    try testing.expect(!r.truncated);
}

test "parseRgOutput: files_with_matches counts uniques" {
    const raw = "a.zig\nb.zig\nb.zig\n";
    const r = try parseRgOutput(testing.allocator, raw, .files_with_matches);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), r.file_count);
}

test "containsCi: case-sensitive" {
    try testing.expect(containsCi("Hello World", "World", false));
    try testing.expect(!containsCi("Hello World", "world", false));
}

test "containsCi: case-insensitive" {
    try testing.expect(containsCi("Hello World", "world", true));
    try testing.expect(containsCi("Hello World", "HELLO", true));
    try testing.expect(!containsCi("Hello World", "xyz", true));
}
