//! Assertions.
//!
//! An assertion takes an observed output and a golden expectation
//! and returns a `Verdict`. The crucial rule for Commit 46:
//! **every failure path must produce a witness**. A verdict that
//! says "failed" without a `failure_witness` is rejected at
//! construction so bugs in custom assertions never ship as silent
//! fails.
//!
//! Witness semantics:
//!   * On pass: `failure_witness` is empty and `witness_source_hash`
//!     is unset.
//!   * On fail: `failure_witness.len > 0` AND `witness_source_hash`
//!     is set. The hash pins what input produced the witness so a
//!     future change that regenerates the witness can be caught.
//!   * Cardinality: at most 16 witnesses per run (see
//!     `witness_cardinality_test`). Runs with more witnesses are
//!     almost certainly bugs in the assertion emitting fragments
//!     instead of a single diagnostic.

const std = @import("std");
const hash_guard = @import("../bench/hash_guard.zig");

pub const max_witnesses_per_run: usize = 16;

pub const Verdict = struct {
    passed: bool,
    score: f64,
    failure_witness: []const u8,
    witness_source_hash: hash_guard.Digest,

    /// Validate the verdict's invariants. Returns an error on any
    /// violation; callers use this at the edge of the assertion
    /// subsystem to catch bugs in custom assertions.
    pub fn validate(self: Verdict) !void {
        if (self.passed) {
            if (self.failure_witness.len != 0) return error.PassWithWitness;
            if (self.witness_source_hash.isSet()) return error.PassWithWitnessHash;
        } else {
            if (self.failure_witness.len == 0) return error.FailWithoutWitness;
            if (!self.witness_source_hash.isSet()) return error.FailWithoutWitnessHash;
        }
    }
};

pub const Error = error{
    PassWithWitness,
    PassWithWitnessHash,
    FailWithoutWitness,
    FailWithoutWitnessHash,
    WitnessCardinalityExceeded,
};

/// Enforce the per-run cardinality cap across a slice of verdicts.
pub fn checkCardinality(verdicts: []const Verdict) !void {
    var witnesses: usize = 0;
    for (verdicts) |v| {
        if (!v.passed) witnesses += 1;
    }
    if (witnesses > max_witnesses_per_run) return error.WitnessCardinalityExceeded;
}

/// Canonical built-in assertion: byte-for-byte equality.
pub fn exactEq(
    allocator: std.mem.Allocator,
    observed: []const u8,
    expected: []const u8,
) !Verdict {
    if (std.mem.eql(u8, observed, expected)) {
        return .{
            .passed = true,
            .score = 1.0,
            .failure_witness = "",
            .witness_source_hash = .{ .hex = "" },
        };
    }
    const witness = try std.fmt.allocPrint(
        allocator,
        "observed({d}b) != expected({d}b)",
        .{ observed.len, expected.len },
    );
    errdefer allocator.free(witness);
    const h = try hash_guard.sha256Hex(allocator, expected);
    return .{
        .passed = false,
        .score = 0.0,
        .failure_witness = witness,
        .witness_source_hash = h,
    };
}

pub fn freeVerdict(allocator: std.mem.Allocator, v: Verdict) void {
    if (v.failure_witness.len > 0) allocator.free(v.failure_witness);
    if (v.witness_source_hash.isSet()) hash_guard.freeDigest(allocator, v.witness_source_hash);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "exactEq: equal strings pass with score 1.0" {
    const v = try exactEq(testing.allocator, "hello", "hello");
    defer freeVerdict(testing.allocator, v);
    try v.validate();
    try testing.expect(v.passed);
    try testing.expectEqual(@as(f64, 1.0), v.score);
}

test "exactEq: unequal strings fail with a witness and a hash" {
    const v = try exactEq(testing.allocator, "hi", "hello");
    defer freeVerdict(testing.allocator, v);
    try v.validate();
    try testing.expect(!v.passed);
    try testing.expect(v.failure_witness.len > 0);
    try testing.expect(v.witness_source_hash.isSet());
}

test "validate: pass with a witness is a bug" {
    const v = Verdict{
        .passed = true,
        .score = 1.0,
        .failure_witness = "leaked",
        .witness_source_hash = .{ .hex = "" },
    };
    try testing.expectError(Error.PassWithWitness, v.validate());
}

test "validate: fail without a witness is a bug" {
    const v = Verdict{
        .passed = false,
        .score = 0.0,
        .failure_witness = "",
        .witness_source_hash = .{ .hex = "" },
    };
    try testing.expectError(Error.FailWithoutWitness, v.validate());
}

test "checkCardinality: at cap is ok, over is rejected" {
    var ok_list: [max_witnesses_per_run]Verdict = undefined;
    for (&ok_list) |*v| {
        v.* = .{
            .passed = false,
            .score = 0.0,
            .failure_witness = "w",
            .witness_source_hash = .{ .hex = "deadbeef" },
        };
    }
    try checkCardinality(&ok_list);

    var too_many: [max_witnesses_per_run + 1]Verdict = undefined;
    for (&too_many) |*v| {
        v.* = ok_list[0];
    }
    try testing.expectError(Error.WitnessCardinalityExceeded, checkCardinality(&too_many));
}
