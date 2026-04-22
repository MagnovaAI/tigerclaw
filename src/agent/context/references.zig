//! File / artefact references pulled out of the transcript.
//!
//! The context engine trims old messages aggressively, but the
//! references those messages pointed at (a file path the agent
//! was editing, a URL the user shared) often matter for later
//! turns. `References` is a tiny ordered set that collects them
//! so compaction can keep a short "still relevant" trailer even
//! when the raw message bodies are gone.
//!
//! Ownership: entries are heap-duplicated; `deinit` frees them.

const std = @import("std");

pub const Kind = enum { file, url, artifact };

pub const Reference = struct {
    kind: Kind,
    /// Canonical string the caller knows how to reopen (path, URL,
    /// artefact id). Not parsed here.
    value: []const u8,
};

pub const References = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Reference),

    pub fn init(allocator: std.mem.Allocator) References {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *References) void {
        for (self.items.items) |r| self.allocator.free(r.value);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert if absent. Entries are compared by `(kind, value)`;
    /// a repeated insert of the same reference is a no-op (no
    /// duplicates, no clobber). Returns `true` if a new entry
    /// was added.
    pub fn add(self: *References, kind: Kind, value: []const u8) !bool {
        for (self.items.items) |r| {
            if (r.kind == kind and std.mem.eql(u8, r.value, value)) return false;
        }
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        try self.items.append(self.allocator, .{ .kind = kind, .value = copy });
        return true;
    }

    pub fn len(self: *const References) usize {
        return self.items.items.len;
    }

    pub fn slice(self: *const References) []const Reference {
        return self.items.items;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "References: add dedupes by (kind, value)" {
    var r = References.init(testing.allocator);
    defer r.deinit();

    try testing.expect(try r.add(.file, "/a"));
    try testing.expect(!try r.add(.file, "/a"));
    try testing.expect(try r.add(.file, "/b"));
    // Same value, different kind is still unique.
    try testing.expect(try r.add(.url, "/a"));

    try testing.expectEqual(@as(usize, 3), r.len());
}

test "References: values are heap-copied" {
    var r = References.init(testing.allocator);
    defer r.deinit();

    var buf = [_]u8{ 'h', 'i' };
    _ = try r.add(.artifact, &buf);
    buf[0] = 'X';
    try testing.expectEqualStrings("hi", r.slice()[0].value);
}
