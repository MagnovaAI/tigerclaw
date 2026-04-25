//! Recursive workspace glob with ignore-dir awareness, mtime-desc
//! ordering, and a hard match cap.
//!
//! Pattern syntax:
//!   *  matches any run of chars within one path segment
//!   ** matches zero or more path segments (recursive)
//!   ?  matches exactly one char within a segment
//!   [abc] character class
//!   {a,b,c} brace alternation, expanded into multiple sibling patterns
//!
//! Hidden entries (names starting with `.`) are skipped unless the
//! pattern's matching segment also starts with `.`. A short list of
//! "noise" directory names (.git, node_modules, target, ...) is
//! pruned regardless of pattern.

const std = @import("std");

pub const GlobError = error{
    PathEscapesWorkspace,
    InvalidPath,
    InvalidPattern,
    OpenFailed,
} || std.mem.Allocator.Error;

pub const GlobOptions = struct {
    /// Glob pattern.
    pattern: []const u8,
    /// Workspace-relative search root. null/"" = workspace root.
    path: ?[]const u8 = null,
};

pub const GlobMatch = struct {
    /// Workspace-relative path, owned.
    path: []u8,
    mtime_ns: i128,

    pub fn deinit(self: GlobMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const GlobResult = struct {
    matches: []GlobMatch,
    truncated: bool,

    pub fn deinit(self: GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches) |m| m.deinit(allocator);
        allocator.free(self.matches);
    }
};

/// Hard match cap.
pub const MAX_MATCHES: usize = 500;

/// Hard cap on the number of brace-expanded patterns; an
/// `{a,b}/{c,d}/{e,f,g}` is fine, anything beyond explodes the search.
pub const MAX_EXPANDED_PATTERNS: usize = 64;

const IGNORE_DIR_NAMES = [_][]const u8{
    ".git",         ".zig-cache", "zig-out",
    "node_modules", "target",     "dist",
    "build",        ".venv",      "venv",
    "__pycache__",  ".next",      ".cache",
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    opts: GlobOptions,
) GlobError!GlobResult {
    const sub = opts.path orelse "";

    // Expand any brace alternations into a list of plain patterns.
    var patterns: std.ArrayList([]u8) = .empty;
    defer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit(allocator);
    }
    expandBraces(allocator, opts.pattern, &patterns) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPattern,
    };
    if (patterns.items.len == 0) return error.InvalidPattern;
    if (patterns.items.len > MAX_EXPANDED_PATTERNS) return error.InvalidPattern;

    var matches: std.ArrayList(GlobMatch) = .empty;
    errdefer {
        for (matches.items) |m| m.deinit(allocator);
        matches.deinit(allocator);
    }

    var truncated = false;

    var root_dir = openSearchRoot(io, workspace_root, sub) catch return error.OpenFailed;
    defer root_dir.close(io);

    var walker = root_dir.walkSelectively(allocator) catch return error.OpenFailed;
    defer walker.deinit();

    while (true) {
        const maybe = walker.next(io) catch break;
        const entry = maybe orelse break;

        const basename = entry.basename;
        const rel_path = entry.path; // sentinel-terminated, valid until next next()

        // Prune well-known noise directories before descending.
        if (entry.kind == .directory) {
            if (isIgnoredDir(basename) or
                (basename.len > 0 and basename[0] == '.' and !patternAllowsHidden(patterns.items, entry.depth())))
            {
                // Don't enter; SelectiveWalker only descends on enter().
                continue;
            }
            walker.enter(io, entry) catch continue;
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;

        // Hidden file: skip unless the matching pattern segment also starts with '.'.
        if (basename[0] == '.' and !patternAllowsHidden(patterns.items, entry.depth())) continue;

        // Try every expanded pattern.
        var any_match = false;
        for (patterns.items) |pat| {
            if (matchFullPath(pat, rel_path)) {
                any_match = true;
                break;
            }
        }
        if (!any_match) continue;

        // Accept. Stat for mtime so we can sort.
        const owned_path = try allocator.dupe(u8, rel_path);
        errdefer allocator.free(owned_path);

        const mtime_ns: i128 = blk: {
            var f = entry.dir.openFile(io, basename, .{}) catch break :blk 0;
            defer f.close(io);
            const st = f.stat(io) catch break :blk 0;
            break :blk st.mtime.toNanoseconds();
        };

        if (matches.items.len >= MAX_MATCHES) {
            truncated = true;
            allocator.free(owned_path);
            break;
        }
        try matches.append(allocator, .{ .path = owned_path, .mtime_ns = mtime_ns });
    }

    std.sort.block(GlobMatch, matches.items, {}, mtimeDescLess);

    return .{
        .matches = try matches.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

fn mtimeDescLess(_: void, a: GlobMatch, b: GlobMatch) bool {
    return a.mtime_ns > b.mtime_ns;
}

fn openSearchRoot(io: std.Io, workspace_root: []const u8, sub: []const u8) !std.Io.Dir {
    var root = if (workspace_root.len == 0)
        std.Io.Dir.cwd()
    else
        try std.Io.Dir.cwd().openDir(io, workspace_root, .{});
    if (sub.len == 0 or std.mem.eql(u8, sub, ".")) {
        if (workspace_root.len == 0) return root;
        // Re-open with iterate=true for the walker.
        defer root.close(io);
        return std.Io.Dir.cwd().openDir(io, workspace_root, .{ .iterate = true });
    }
    defer root.close(io);
    return std.Io.Dir.cwd().openDir(
        io,
        if (workspace_root.len == 0)
            sub
        else
            sub,
        .{ .iterate = true },
    );
}

pub fn isIgnoredDir(name: []const u8) bool {
    for (IGNORE_DIR_NAMES) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

/// Coarse heuristic: hidden files participate when at least one
/// pattern starts the right-depth segment with `.`. Without a
/// per-segment match we fall back on "the pattern as a whole begins
/// with a literal dot."
fn patternAllowsHidden(patterns: []const []u8, depth: usize) bool {
    _ = depth;
    for (patterns) |p| {
        if (p.len > 0 and p[0] == '.') return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Brace expansion: `{a,b}/c` -> ["a/c", "b/c"]; nested supported.

pub const ExpandError = error{InvalidPattern} || std.mem.Allocator.Error;

pub fn expandBraces(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    out: *std.ArrayList([]u8),
) ExpandError!void {
    // Find the first '{ ... }' group at the outermost depth.
    var i: usize = 0;
    var depth: usize = 0;
    var open_at: ?usize = null;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '{' => {
                if (depth == 0) open_at = i;
                depth += 1;
            },
            '}' => {
                if (depth == 0) return error.InvalidPattern;
                depth -= 1;
                if (depth == 0) {
                    const start = open_at.?;
                    const end = i;
                    const prefix = pattern[0..start];
                    const inside = pattern[start + 1 .. end];
                    const suffix = pattern[end + 1 ..];
                    var j: usize = 0;
                    var part_start: usize = 0;
                    var sub_depth: usize = 0;
                    while (j < inside.len) : (j += 1) {
                        switch (inside[j]) {
                            '{' => sub_depth += 1,
                            '}' => sub_depth -= 1,
                            ',' => if (sub_depth == 0) {
                                try expandBracesPart(allocator, prefix, inside[part_start..j], suffix, out);
                                part_start = j + 1;
                            },
                            else => {},
                        }
                    }
                    try expandBracesPart(allocator, prefix, inside[part_start..], suffix, out);
                    return;
                }
            },
            else => {},
        }
    }
    if (depth != 0) return error.InvalidPattern;
    try out.append(allocator, try allocator.dupe(u8, pattern));
}

fn expandBracesPart(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    middle: []const u8,
    suffix: []const u8,
    out: *std.ArrayList([]u8),
) ExpandError!void {
    const buf = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, middle, suffix });
    defer allocator.free(buf);
    try expandBraces(allocator, buf, out);
}

// ---------------------------------------------------------------------------
// Whole-path matcher with `**` segment.

/// Hard cap on path-segment count; deeper paths are simply not matched.
const MAX_PATH_SEGS: usize = 64;

const SegArray = struct {
    data: [MAX_PATH_SEGS][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const SegArray) []const []const u8 {
        return self.data[0..self.len];
    }
};

fn splitSegments(s: []const u8) SegArray {
    var arr: SegArray = .{};
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (arr.len >= MAX_PATH_SEGS) break;
        arr.data[arr.len] = seg;
        arr.len += 1;
    }
    return arr;
}

/// Match a glob pattern against a slash-separated path. Pattern
/// segments are split on `/`; a single `**` segment matches zero or
/// more path segments. Other segments use per-segment `matchSeg`.
pub fn matchFullPath(pattern: []const u8, path: []const u8) bool {
    const p_segs = splitSegments(pattern);
    const x_segs = splitSegments(path);
    return matchSegs(p_segs.slice(), 0, x_segs.slice(), 0);
}

fn matchSegs(p_segs: []const []const u8, pi: usize, x_segs: []const []const u8, xi: usize) bool {
    if (pi == p_segs.len) return xi == x_segs.len;
    const p = p_segs[pi];
    if (std.mem.eql(u8, p, "**")) {
        // ** matches zero or more segments.
        var k = xi;
        while (k <= x_segs.len) : (k += 1) {
            if (matchSegs(p_segs, pi + 1, x_segs, k)) return true;
        }
        return false;
    }
    if (xi == x_segs.len) return false;
    if (!matchSeg(p, x_segs[xi])) return false;
    return matchSegs(p_segs, pi + 1, x_segs, xi + 1);
}

pub fn matchSeg(pattern: []const u8, name: []const u8) bool {
    return matchAt(pattern, 0, name, 0);
}

fn matchAt(pattern: []const u8, pi: usize, name: []const u8, ni: usize) bool {
    if (pi >= pattern.len) return ni >= name.len;
    const pc = pattern[pi];
    if (pc == '*') {
        var pj = pi;
        while (pj < pattern.len and pattern[pj] == '*') : (pj += 1) {}
        if (pj >= pattern.len) return true;
        var k = ni;
        while (k <= name.len) : (k += 1) {
            if (matchAt(pattern, pj, name, k)) return true;
        }
        return false;
    }
    if (pc == '?') {
        if (ni >= name.len) return false;
        return matchAt(pattern, pi + 1, name, ni + 1);
    }
    if (pc == '[') {
        const cls_end = std.mem.indexOfScalarPos(u8, pattern, pi + 1, ']') orelse return false;
        if (ni >= name.len) return false;
        const class = pattern[pi + 1 .. cls_end];
        var matched = false;
        for (class) |cc| {
            if (cc == name[ni]) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
        return matchAt(pattern, cls_end + 1, name, ni + 1);
    }
    if (ni >= name.len) return false;
    if (pc != name[ni]) return false;
    return matchAt(pattern, pi + 1, name, ni + 1);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "matchSeg: literal" {
    try testing.expect(matchSeg("foo", "foo"));
    try testing.expect(!matchSeg("foo", "bar"));
}

test "matchSeg: star at end" {
    try testing.expect(matchSeg("foo*", "foobar"));
    try testing.expect(matchSeg("*.zig", "main.zig"));
    try testing.expect(!matchSeg("*.zig", "main.go"));
}

test "matchSeg: ? matches single char" {
    try testing.expect(matchSeg("a?c", "abc"));
    try testing.expect(!matchSeg("a?c", "ac"));
    try testing.expect(!matchSeg("a?c", "abcd"));
}

test "matchSeg: character class" {
    try testing.expect(matchSeg("[abc]", "a"));
    try testing.expect(matchSeg("[abc]", "b"));
    try testing.expect(!matchSeg("[abc]", "d"));
    try testing.expect(matchSeg("foo[12]", "foo1"));
    try testing.expect(!matchSeg("foo[12]", "foo3"));
}

test "matchFullPath: literal segments" {
    try testing.expect(matchFullPath("src/main.zig", "src/main.zig"));
    try testing.expect(!matchFullPath("src/main.zig", "src/lib.zig"));
}

test "matchFullPath: ** matches zero or more dirs" {
    try testing.expect(matchFullPath("src/**/*.zig", "src/main.zig"));
    try testing.expect(matchFullPath("src/**/*.zig", "src/cli/commands/foo.zig"));
    try testing.expect(!matchFullPath("src/**/*.zig", "tests/foo.zig"));
}

test "matchFullPath: bare *.zig" {
    try testing.expect(matchFullPath("*.zig", "main.zig"));
    try testing.expect(!matchFullPath("*.zig", "src/main.zig"));
}

test "isIgnoredDir: well-known noise" {
    try testing.expect(isIgnoredDir(".git"));
    try testing.expect(isIgnoredDir("node_modules"));
    try testing.expect(isIgnoredDir(".zig-cache"));
    try testing.expect(!isIgnoredDir("src"));
    try testing.expect(!isIgnoredDir("tests"));
}

test "expandBraces: single literal yields one pattern" {
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |p| testing.allocator.free(p);
        out.deinit(testing.allocator);
    }
    try expandBraces(testing.allocator, "src/foo.zig", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("src/foo.zig", out.items[0]);
}

test "expandBraces: simple alternation" {
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |p| testing.allocator.free(p);
        out.deinit(testing.allocator);
    }
    try expandBraces(testing.allocator, "*.{ts,tsx}", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("*.ts", out.items[0]);
    try testing.expectEqualStrings("*.tsx", out.items[1]);
}

test "expandBraces: nested" {
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |p| testing.allocator.free(p);
        out.deinit(testing.allocator);
    }
    try expandBraces(testing.allocator, "{a,b}/{c,d}", &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);
}
