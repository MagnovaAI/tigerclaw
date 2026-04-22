//! Structural diff between two span streams.
//!
//! The diff compares two traces by `(parent_id, kind, name)` key. It is
//! deliberately shape-oriented: exact timing and attribute text drift
//! across runs, but the structural shape of the trace (which spans,
//! their kinds, their parent relationships, their completion status) is
//! what replay verification cares about.
//!
//! Two spans *align* when they share `(kind, name, parent_id)`. The diff
//! walks the expected list in order; each unmatched expected span is
//! reported as `missing`, each extra actual span as `extra`, and aligned
//! spans with mismatching completion status are reported as `status`.

const std = @import("std");
const span_mod = @import("span.zig");

pub const Kind = enum {
    missing,
    extra,
    status,
};

pub const Entry = struct {
    kind: Kind,
    span_name: []const u8,
    detail: []const u8,
};

pub const Report = struct {
    entries: []Entry,

    pub fn empty(self: Report) bool {
        return self.entries.len == 0;
    }

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.span_name);
            allocator.free(e.detail);
        }
        allocator.free(self.entries);
    }
};

pub fn diff(
    allocator: std.mem.Allocator,
    expected: []const span_mod.Span,
    actual: []const span_mod.Span,
) !Report {
    var entries: std.array_list.Aligned(Entry, null) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.span_name);
            allocator.free(e.detail);
        }
        entries.deinit(allocator);
    }

    var consumed = try allocator.alloc(bool, actual.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    for (expected) |want| {
        const match_idx = findMatch(want, actual, consumed);
        if (match_idx == null) {
            try entries.append(allocator, .{
                .kind = .missing,
                .span_name = try allocator.dupe(u8, want.name),
                .detail = try allocator.dupe(u8, @tagName(want.kind)),
            });
            continue;
        }
        consumed[match_idx.?] = true;

        const got = actual[match_idx.?];
        if (got.status != want.status) {
            const detail = try std.fmt.allocPrint(allocator, "expected {s}, got {s}", .{
                @tagName(want.status), @tagName(got.status),
            });
            try entries.append(allocator, .{
                .kind = .status,
                .span_name = try allocator.dupe(u8, want.name),
                .detail = detail,
            });
        }
    }

    for (actual, 0..) |extra, i| {
        if (!consumed[i]) {
            try entries.append(allocator, .{
                .kind = .extra,
                .span_name = try allocator.dupe(u8, extra.name),
                .detail = try allocator.dupe(u8, @tagName(extra.kind)),
            });
        }
    }

    const owned = try entries.toOwnedSlice(allocator);
    return .{ .entries = owned };
}

fn findMatch(want: span_mod.Span, actual: []const span_mod.Span, consumed: []const bool) ?usize {
    for (actual, 0..) |s, i| {
        if (consumed[i]) continue;
        if (s.kind != want.kind) continue;
        if (!std.mem.eql(u8, s.name, want.name)) continue;
        if (!optEqlStr(s.parent_id, want.parent_id)) continue;
        return i;
    }
    return null;
}

fn optEqlStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn mkSpan(name: []const u8, kind: span_mod.Kind, parent: ?[]const u8, status: span_mod.Status) span_mod.Span {
    return .{
        .id = name,
        .parent_id = parent,
        .trace_id = "t",
        .kind = kind,
        .name = name,
        .started_at_ns = 0,
        .finished_at_ns = 1,
        .status = status,
    };
}

test "diff: identical streams produce an empty report" {
    const a = [_]span_mod.Span{
        mkSpan("root", .root, null, .ok),
        mkSpan("turn-1", .turn, "root", .ok),
    };
    const r = try diff(testing.allocator, &a, &a);
    defer r.deinit(testing.allocator);
    try testing.expect(r.empty());
}

test "diff: missing span reported" {
    const expected = [_]span_mod.Span{
        mkSpan("root", .root, null, .ok),
        mkSpan("turn-1", .turn, "root", .ok),
    };
    const actual = [_]span_mod.Span{
        mkSpan("root", .root, null, .ok),
    };

    const r = try diff(testing.allocator, &expected, &actual);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.entries.len);
    try testing.expectEqual(Kind.missing, r.entries[0].kind);
    try testing.expectEqualStrings("turn-1", r.entries[0].span_name);
}

test "diff: extra span reported" {
    const expected = [_]span_mod.Span{
        mkSpan("root", .root, null, .ok),
    };
    const actual = [_]span_mod.Span{
        mkSpan("root", .root, null, .ok),
        mkSpan("turn-bonus", .turn, "root", .ok),
    };

    const r = try diff(testing.allocator, &expected, &actual);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.entries.len);
    try testing.expectEqual(Kind.extra, r.entries[0].kind);
    try testing.expectEqualStrings("turn-bonus", r.entries[0].span_name);
}

test "diff: status mismatch reported" {
    const expected = [_]span_mod.Span{mkSpan("turn-1", .turn, null, .ok)};
    const actual = [_]span_mod.Span{mkSpan("turn-1", .turn, null, .err)};

    const r = try diff(testing.allocator, &expected, &actual);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.entries.len);
    try testing.expectEqual(Kind.status, r.entries[0].kind);
    try testing.expect(std.mem.indexOf(u8, r.entries[0].detail, "expected ok") != null);
    try testing.expect(std.mem.indexOf(u8, r.entries[0].detail, "got err") != null);
}

test "diff: parent_id difference prevents alignment" {
    const expected = [_]span_mod.Span{
        mkSpan("child", .turn, "parent-a", .ok),
    };
    const actual = [_]span_mod.Span{
        mkSpan("child", .turn, "parent-b", .ok),
    };
    const r = try diff(testing.allocator, &expected, &actual);
    defer r.deinit(testing.allocator);
    // Expected span is missing under parent-a; actual span is extra under parent-b.
    try testing.expectEqual(@as(usize, 2), r.entries.len);
}
