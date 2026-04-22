//! Dataset / golden / rubric hash guard.
//!
//! Before comparing two bench runs, we must be sure both ran
//! against the *same* inputs. Otherwise "candidate regressed"
//! might mean "candidate ran a harder dataset". Per ADR 0009, the
//! trace envelope carries four hash slots (`dataset_hash`,
//! `golden_hash`, `rubric_hash`, `mutation_hash`); this file is
//! the arithmetic that produces them and the gate that rejects
//! mismatched tuples at compare time.

const std = @import("std");

pub const Digest = struct {
    /// Owned lowercase hex. Zero-length means "unset".
    hex: []const u8,

    pub fn isSet(self: Digest) bool {
        return self.hex.len > 0;
    }

    pub fn equals(self: Digest, other: Digest) bool {
        return std.mem.eql(u8, self.hex, other.hex);
    }
};

/// Compute SHA-256 of `bytes` and return a lowercase-hex `Digest`
/// allocated into `allocator`.
pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) !Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);

    const out = try allocator.alloc(u8, raw.len * 2);
    errdefer allocator.free(out);
    _ = std.fmt.bufPrint(out, "{x}", .{&raw}) catch unreachable;
    return .{ .hex = out };
}

pub fn freeDigest(allocator: std.mem.Allocator, d: Digest) void {
    if (d.hex.len > 0) allocator.free(d.hex);
}

/// Tuple describing a run's hashed inputs.
pub const HashTuple = struct {
    dataset: Digest = .{ .hex = "" },
    golden: Digest = .{ .hex = "" },
    rubric: Digest = .{ .hex = "" },
    mutation: Digest = .{ .hex = "" },
};

pub const MismatchReason = enum {
    none,
    dataset,
    golden,
    rubric,
    mutation,
};

/// Compare two tuples. Any difference — including one side unset
/// while the other is set — counts as a mismatch; unset slots on
/// both sides match. Returns the first axis that disagrees, in
/// declaration order, so callers can log a specific reason.
pub fn compareTuples(a: HashTuple, b: HashTuple) MismatchReason {
    if (!digestsMatch(a.dataset, b.dataset)) return .dataset;
    if (!digestsMatch(a.golden, b.golden)) return .golden;
    if (!digestsMatch(a.rubric, b.rubric)) return .rubric;
    if (!digestsMatch(a.mutation, b.mutation)) return .mutation;
    return .none;
}

fn digestsMatch(a: Digest, b: Digest) bool {
    if (a.isSet() != b.isSet()) return false;
    if (!a.isSet()) return true;
    return a.equals(b);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "sha256Hex: two identical buffers hash to identical hex" {
    const a = try sha256Hex(testing.allocator, "hello");
    defer freeDigest(testing.allocator, a);
    const b = try sha256Hex(testing.allocator, "hello");
    defer freeDigest(testing.allocator, b);
    try testing.expect(a.equals(b));
    try testing.expectEqual(@as(usize, 64), a.hex.len);
}

test "compareTuples: identical tuples match" {
    const x = try sha256Hex(testing.allocator, "dataset");
    defer freeDigest(testing.allocator, x);
    const a = HashTuple{ .dataset = x };
    const b = HashTuple{ .dataset = x };
    try testing.expectEqual(MismatchReason.none, compareTuples(a, b));
}

test "compareTuples: unset-on-one-side is still a mismatch" {
    const x = try sha256Hex(testing.allocator, "d");
    defer freeDigest(testing.allocator, x);
    const a = HashTuple{ .dataset = x };
    const b = HashTuple{};
    try testing.expectEqual(MismatchReason.dataset, compareTuples(a, b));
}

test "compareTuples: both unset matches (ok)" {
    try testing.expectEqual(MismatchReason.none, compareTuples(.{}, .{}));
}

test "compareTuples: axis order is the tie-breaker" {
    const d = try sha256Hex(testing.allocator, "d");
    defer freeDigest(testing.allocator, d);
    const g = try sha256Hex(testing.allocator, "g");
    defer freeDigest(testing.allocator, g);

    const a = HashTuple{ .dataset = d, .golden = g };
    const b = HashTuple{};
    // Dataset disagrees first, in declaration order.
    try testing.expectEqual(MismatchReason.dataset, compareTuples(a, b));
}
