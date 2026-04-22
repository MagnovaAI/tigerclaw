//! Witness cardinality cap: a run may carry at most 16 failing
//! verdicts. More than that is almost always a bug in the
//! assertion emitting fragments rather than a single diagnostic.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const assertion = tigerclaw.eval.assertion;

fn failing() tigerclaw.eval.Verdict {
    return .{
        .passed = false,
        .score = 0.0,
        .failure_witness = "w",
        .witness_source_hash = .{ .hex = "deadbeef" },
    };
}

test "witness cardinality: at 16 is ok" {
    var list: [assertion.max_witnesses_per_run]tigerclaw.eval.Verdict = undefined;
    for (&list) |*v| v.* = failing();
    try assertion.checkCardinality(&list);
}

test "witness cardinality: 17 is rejected" {
    var list: [assertion.max_witnesses_per_run + 1]tigerclaw.eval.Verdict = undefined;
    for (&list) |*v| v.* = failing();
    try testing.expectError(
        assertion.Error.WitnessCardinalityExceeded,
        assertion.checkCardinality(&list),
    );
}

test "witness cardinality: passing verdicts never count against the cap" {
    // 32 passing verdicts, zero failures: ok regardless of count.
    var list: [32]tigerclaw.eval.Verdict = undefined;
    for (&list) |*v| v.* = .{
        .passed = true,
        .score = 1.0,
        .failure_witness = "",
        .witness_source_hash = .{ .hex = "" },
    };
    try assertion.checkCardinality(&list);
}
