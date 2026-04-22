//! Approval cache.
//!
//! When the user answers a prompt with `Scope.session` or
//! `Scope.persistent`, that answer is cached in a `Store` keyed by
//! `(ActionKind, target)`. Subsequent actions with the same key
//! skip the prompt and use the cached decision.
//!
//! Scope semantics today:
//!
//!   * `once`        — never cached.
//!   * `session`     — cached in memory until the session ends.
//!   * `persistent`  — cached in memory the same way; persisting
//!     to disk is a future change (tracked on the roadmap). The
//!     enum still accepts it so callers and the UI layer do not
//!     need to branch on a phantom variant.
//!
//! Denials are also cached: repeatedly asking the same denied
//! question would be obnoxious and is a small exfil vector (the
//! user might click "allow" under prompt fatigue).

const std = @import("std");
const policy_mod = @import("policy.zig");
const prompt_mod = @import("prompt.zig");

/// Composite key: the action kind and its target string.
/// We deliberately do not dedupe by prefix or any semantic
/// normalisation — the cache mirrors what the user answered,
/// verbatim. Broader allowances belong in `Policy.overrides`,
/// not in this cache.
pub const Key = struct {
    kind: policy_mod.ActionKind,
    target: []const u8,
};

pub const Entry = struct {
    approved: bool,
    scope: prompt_mod.Scope,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    /// `StringHashMap` indexed by a composed "<kind>:<target>" key.
    /// Composing once at insert keeps lookup a single hash.
    map: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.deinit();
    }

    fn makeKey(self: *Store, key: Key) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ @tagName(key.kind), key.target });
    }

    /// Record a response. `.once` responses are never cached so
    /// that a one-off confirmation does not accidentally unlock a
    /// whole session.
    pub fn record(self: *Store, key: Key, response: prompt_mod.Response) !void {
        if (response.remember == .once) return;
        const composed = try self.makeKey(key);
        errdefer self.allocator.free(composed);
        const gop = try self.map.getOrPut(composed);
        if (gop.found_existing) {
            self.allocator.free(composed);
        }
        gop.value_ptr.* = .{ .approved = response.approved, .scope = response.remember };
    }

    /// Look up a cached answer. `null` means "no cached answer —
    /// ask the user again".
    pub fn lookup(self: *Store, key: Key) !?Entry {
        const composed = try self.makeKey(key);
        defer self.allocator.free(composed);
        return self.map.get(composed);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Store: record/lookup round-trips for session scope" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.record(
        .{ .kind = .fs_write, .target = "/tmp/x" },
        .{ .approved = true, .remember = .session },
    );

    const hit = (try s.lookup(.{ .kind = .fs_write, .target = "/tmp/x" })).?;
    try testing.expect(hit.approved);
    try testing.expectEqual(prompt_mod.Scope.session, hit.scope);
}

test "Store: once responses are never cached" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.record(
        .{ .kind = .fs_write, .target = "/tmp/x" },
        prompt_mod.Response.allowOnce(),
    );

    try testing.expect((try s.lookup(.{ .kind = .fs_write, .target = "/tmp/x" })) == null);
}

test "Store: denials are cached too so prompt fatigue cannot flip the answer" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.record(
        .{ .kind = .exec, .target = "/bin/rm" },
        .{ .approved = false, .remember = .session },
    );

    const hit = (try s.lookup(.{ .kind = .exec, .target = "/bin/rm" })).?;
    try testing.expect(!hit.approved);
}

test "Store: key includes kind so the same target across kinds is independent" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.record(
        .{ .kind = .fs_read, .target = "/tmp/x" },
        .{ .approved = true, .remember = .session },
    );
    try testing.expect(
        (try s.lookup(.{ .kind = .fs_write, .target = "/tmp/x" })) == null,
    );
    try testing.expect(
        (try s.lookup(.{ .kind = .fs_read, .target = "/tmp/x" })) != null,
    );
}

test "Store: re-recording a key overwrites the earlier answer" {
    var s = Store.init(testing.allocator);
    defer s.deinit();

    try s.record(
        .{ .kind = .fs_write, .target = "/tmp/x" },
        .{ .approved = true, .remember = .session },
    );
    try s.record(
        .{ .kind = .fs_write, .target = "/tmp/x" },
        .{ .approved = false, .remember = .session },
    );

    const hit = (try s.lookup(.{ .kind = .fs_write, .target = "/tmp/x" })).?;
    try testing.expect(!hit.approved);
}
