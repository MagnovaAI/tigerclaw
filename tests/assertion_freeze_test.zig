//! Freeze test for the Verdict invariants that Commit 46
//! enforces. If any future change weakens these, this test
//! fails and CI refuses the commit.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const eval = tigerclaw.eval;
const assertion = eval.assertion;

test "assertion freeze: passing verdict with a witness is rejected" {
    const v = eval.Verdict{
        .passed = true,
        .score = 1.0,
        .failure_witness = "leaked",
        .witness_source_hash = .{ .hex = "" },
    };
    try testing.expectError(assertion.Error.PassWithWitness, v.validate());
}

test "assertion freeze: failing verdict without a witness is rejected" {
    const v = eval.Verdict{
        .passed = false,
        .score = 0.0,
        .failure_witness = "",
        .witness_source_hash = .{ .hex = "" },
    };
    try testing.expectError(assertion.Error.FailWithoutWitness, v.validate());
}

test "assertion freeze: failing verdict without a witness hash is rejected" {
    const v = eval.Verdict{
        .passed = false,
        .score = 0.0,
        .failure_witness = "something broke",
        .witness_source_hash = .{ .hex = "" },
    };
    try testing.expectError(assertion.Error.FailWithoutWitnessHash, v.validate());
}

test "assertion freeze: exactEq failure carries witness + witness hash" {
    const v = try assertion.exactEq(testing.allocator, "a", "b");
    defer assertion.freeVerdict(testing.allocator, v);
    try v.validate();
    try testing.expect(!v.passed);
    try testing.expect(v.failure_witness.len > 0);
    try testing.expect(v.witness_source_hash.isSet());
}
