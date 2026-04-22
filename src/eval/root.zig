//! Eval subsystem: datasets, golden files, bless, report,
//! assertions, rubrics, and the heuristic judge.

const std = @import("std");

pub const dataset = @import("dataset.zig");
pub const golden = @import("golden.zig");
pub const bless = @import("bless.zig");
pub const report = @import("report.zig");
pub const assertion = @import("assertion.zig");
pub const rubric = @import("rubric.zig");
pub const judge = @import("judge.zig");

pub const DatasetItem = dataset.Item;
pub const GoldenEntry = golden.Entry;
pub const Observation = bless.Observation;
pub const Outcome = report.Outcome;
pub const Report = report.Report;
pub const Verdict = assertion.Verdict;
pub const Rubric = rubric.Rubric;
pub const Criterion = rubric.Criterion;
pub const Judgement = judge.Judgement;

test {
    std.testing.refAllDecls(@import("dataset.zig"));
    std.testing.refAllDecls(@import("golden.zig"));
    std.testing.refAllDecls(@import("bless.zig"));
    std.testing.refAllDecls(@import("report.zig"));
    std.testing.refAllDecls(@import("assertion.zig"));
    std.testing.refAllDecls(@import("rubric.zig"));
    std.testing.refAllDecls(@import("judge.zig"));
}
