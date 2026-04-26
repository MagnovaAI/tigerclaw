//! Skill discovery.
//!
//! Scans `<home>/.tigerclaw/skills/<name>/SKILL.md` and parses the
//! YAML frontmatter at the top of each file:
//!
//!     ---
//!     name: my-skill
//!     description: short one-liner shown to the agent
//!     ---
//!
//!     ...prose body the agent reads when invoking the skill...
//!
//! Only the `name` and `description` fields are extracted — they
//! seed the catalog injected into the system prompt and the
//! `/skills` slash command. Body content is left on disk; the
//! agent reads it on demand via the regular `read_file` tool when
//! the user references a skill by name.
//!
//! Missing dirs are silent: returning an empty list is the
//! correct behaviour when the user has no skills installed.

const std = @import("std");

pub const Skill = struct {
    name: []u8,
    description: []u8,
    /// Absolute path to the SKILL.md so the agent can read full
    /// content on demand.
    path: []u8,
    /// Body of the skill, post-frontmatter. Owned. Inlined into
    /// the system prompt so the agent has the instructions
    /// available without needing a separate read_file call —
    /// `read_file` is sandboxed to the agent's workspace and
    /// can't traverse to ~/.tigerclaw/skills anyway.
    body: []u8,
};

pub const List = struct {
    allocator: std.mem.Allocator,
    items: []Skill,

    pub fn deinit(self: *List) void {
        for (self.items) |*s| {
            self.allocator.free(s.name);
            self.allocator.free(s.description);
            self.allocator.free(s.path);
            self.allocator.free(s.body);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Discover skills under `<home>/.tigerclaw/skills/`. Returns an
/// empty list if the directory doesn't exist.
pub fn load(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !List {
    var collected: std.ArrayList(Skill) = .empty;
    errdefer {
        for (collected.items) |*s| {
            allocator.free(s.name);
            allocator.free(s.description);
            allocator.free(s.path);
            allocator.free(s.body);
        }
        collected.deinit(allocator);
    }

    const skills_root = try std.fs.path.join(allocator, &.{ home, ".tigerclaw", "skills" });
    defer allocator.free(skills_root);

    var dir = std.Io.Dir.cwd().openDir(io, skills_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{
            .allocator = allocator,
            .items = try allocator.alloc(Skill, 0),
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const skill_md = try std.fs.path.join(allocator, &.{ skills_root, entry.name, "SKILL.md" });
        errdefer allocator.free(skill_md);

        const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, skill_md, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(skill_md);
                continue;
            },
            else => return err,
        };
        defer allocator.free(file_bytes);

        const meta = parseFrontmatter(file_bytes);
        const name = if (meta.name.len > 0)
            try allocator.dupe(u8, meta.name)
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, meta.description);
        errdefer allocator.free(description);
        const body = try allocator.dupe(u8, meta.body);
        errdefer allocator.free(body);

        try collected.append(allocator, .{
            .name = name,
            .description = description,
            .path = skill_md,
            .body = body,
        });
    }

    const items = try collected.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .items = items };
}

const Frontmatter = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    /// Everything after the closing `---` fence. Empty when the
    /// file has no frontmatter (in which case the whole file
    /// counts as body and gets returned unchanged).
    body: []const u8 = "",
};

/// Tiny ad-hoc YAML reader: only handles `key: value` lines inside
/// a leading `---` / `---` fence. Anything else is ignored. Good
/// enough for skill metadata; not a general YAML parser. Also
/// returns the post-fence body so the caller can ship the full
/// skill text to the model.
fn parseFrontmatter(bytes: []const u8) Frontmatter {
    var meta: Frontmatter = .{};
    if (!std.mem.startsWith(u8, bytes, "---")) {
        // No frontmatter at all — treat the whole file as body.
        meta.body = bytes;
        return meta;
    }

    // Skip the opening fence line.
    var rest = bytes[3..];
    if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];

    // Find the closing fence.
    const end_marker = std.mem.indexOf(u8, rest, "\n---") orelse return meta;
    const block = rest[0..end_marker];

    var line_iter = std.mem.splitScalar(u8, block, '\n');
    while (line_iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\"'");
        if (std.mem.eql(u8, key, "name")) meta.name = value;
        if (std.mem.eql(u8, key, "description")) meta.description = value;
    }

    // Body starts after the closing fence's newline.
    const after_fence = rest[end_marker + 4 ..]; // skip "\n---"
    // Skip the rest of the fence line (e.g. "---\n" or "---  \n").
    const body_start = if (std.mem.indexOfScalar(u8, after_fence, '\n')) |nl| nl + 1 else after_fence.len;
    meta.body = std.mem.trim(u8, after_fence[body_start..], " \t\r\n");

    return meta;
}

test "parseFrontmatter: basic name + description + body" {
    const src =
        \\---
        \\name: hello
        \\description: a friendly greeting
        \\---
        \\
        \\body
    ;
    const meta = parseFrontmatter(src);
    try std.testing.expectEqualStrings("hello", meta.name);
    try std.testing.expectEqualStrings("a friendly greeting", meta.description);
    try std.testing.expectEqualStrings("body", meta.body);
}

test "parseFrontmatter: missing fence returns the whole file as body" {
    const meta = parseFrontmatter("name: nope\n");
    try std.testing.expectEqualStrings("", meta.name);
    try std.testing.expectEqualStrings("", meta.description);
    try std.testing.expectEqualStrings("name: nope\n", meta.body);
}

test "parseFrontmatter: multi-paragraph body preserved" {
    const src =
        \\---
        \\name: x
        \\description: y
        \\---
        \\
        \\First paragraph.
        \\
        \\Second paragraph.
    ;
    const meta = parseFrontmatter(src);
    try std.testing.expectEqualStrings("First paragraph.\n\nSecond paragraph.", meta.body);
}
