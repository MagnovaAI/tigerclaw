//! Tool-selection filter.
//!
//! Not every tool registered with the runtime is useful for every
//! task. Sending an agent a 200-tool schema makes prompts huge,
//! token usage expensive, and selection quality worse — the model
//! has more near-miss options to choose from. This module takes
//! a list of tool specs and narrows it to a subset for the
//! current turn.
//!
//! For this commit we ship the static filters: allow-list,
//! deny-list, and a simple keyword gate against the user's input.
//! Smarter strategies (semantic similarity, per-model whitelists)
//! slot in behind the same `Selector` signature later.

const std = @import("std");

/// A minimal tool descriptor. The tool registry (Commit 39) will
/// own a richer type; we only care about the fields that affect
/// selection.
pub const ToolSpec = struct {
    name: []const u8,
    /// Short, model-facing description. Matches the wire format
    /// every provider accepts — a single paragraph suffices.
    description: []const u8,
    /// Coarse categorisation. Used by `TagSelector` to narrow.
    tags: []const []const u8 = &.{},
};

pub const Context = struct {
    /// Raw user input for this turn, lower-cased before passing
    /// in if case-insensitive keyword matching is wanted.
    user_input: []const u8,
};

pub const Selector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return `true` if the spec should be exposed this turn.
        allow: *const fn (ctx: *anyopaque, spec: ToolSpec, turn: Context) bool,
    };

    pub fn allow(self: Selector, spec: ToolSpec, turn: Context) bool {
        return self.vtable.allow(self.ptr, spec, turn);
    }
};

/// Filter a spec list through a selector. `out` must have room
/// for `specs.len` entries in the worst case; the function returns
/// the count of entries actually written.
pub fn select(
    selector: Selector,
    specs: []const ToolSpec,
    turn: Context,
    out: []ToolSpec,
) usize {
    var n: usize = 0;
    for (specs) |s| {
        if (!selector.allow(s, turn)) continue;
        if (n >= out.len) break;
        out[n] = s;
        n += 1;
    }
    return n;
}

/// Permit every tool. Used when the caller just wants the full
/// registry exposed without writing a filter.
pub const AllowAll = struct {
    pub fn selector(self: *AllowAll) Selector {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn allow(_: *anyopaque, _: ToolSpec, _: Context) bool {
        return true;
    }
    const vtable = Selector.VTable{ .allow = allow };
};

/// Deny anything whose `name` appears in the deny-list. Caller
/// owns the deny-list slice; must outlive the selector.
pub const DenyList = struct {
    names: []const []const u8,

    pub fn selector(self: *DenyList) Selector {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn allow(ptr: *anyopaque, spec: ToolSpec, _: Context) bool {
        const self: *DenyList = @ptrCast(@alignCast(ptr));
        for (self.names) |n| if (std.mem.eql(u8, spec.name, n)) return false;
        return true;
    }
    const vtable = Selector.VTable{ .allow = allow };
};

/// Allow only specs whose `tags` intersect `required`. Callers
/// pre-lower tags and the user input to make matching
/// case-insensitive.
pub const TagSelector = struct {
    required: []const []const u8,

    pub fn selector(self: *TagSelector) Selector {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn allow(ptr: *anyopaque, spec: ToolSpec, _: Context) bool {
        const self: *TagSelector = @ptrCast(@alignCast(ptr));
        for (self.required) |req| {
            for (spec.tags) |t| if (std.mem.eql(u8, t, req)) return true;
        }
        return false;
    }
    const vtable = Selector.VTable{ .allow = allow };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const sample_specs = [_]ToolSpec{
    .{ .name = "read_file", .description = "read a file", .tags = &.{"fs"} },
    .{ .name = "write_file", .description = "write a file", .tags = &.{ "fs", "mutating" } },
    .{ .name = "http_get", .description = "fetch a url", .tags = &.{"net"} },
};

test "select: AllowAll passes everything through" {
    var a = AllowAll{};
    var out: [3]ToolSpec = undefined;
    const n = select(a.selector(), &sample_specs, .{ .user_input = "hi" }, &out);
    try testing.expectEqual(@as(usize, 3), n);
}

test "select: DenyList drops listed names" {
    const deny = [_][]const u8{"write_file"};
    var d = DenyList{ .names = &deny };
    var out: [3]ToolSpec = undefined;
    const n = select(d.selector(), &sample_specs, .{ .user_input = "hi" }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("read_file", out[0].name);
    try testing.expectEqualStrings("http_get", out[1].name);
}

test "select: TagSelector keeps tools whose tags intersect required" {
    const required = [_][]const u8{"fs"};
    var t = TagSelector{ .required = &required };
    var out: [3]ToolSpec = undefined;
    const n = select(t.selector(), &sample_specs, .{ .user_input = "edit" }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("read_file", out[0].name);
    try testing.expectEqualStrings("write_file", out[1].name);
}

test "select: respects out buffer capacity" {
    var a = AllowAll{};
    var out: [2]ToolSpec = undefined; // smaller than specs
    const n = select(a.selector(), &sample_specs, .{ .user_input = "" }, &out);
    try testing.expectEqual(@as(usize, 2), n);
}
