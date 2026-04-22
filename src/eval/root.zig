//! Eval subsystem: datasets, golden files, bless, and the eval
//! report. Assertion/judge/rubric logic lands with Commit 46.

const std = @import("std");

pub const dataset = @import("dataset.zig");
pub const golden = @import("golden.zig");
pub const bless = @import("bless.zig");
pub const report = @import("report.zig");

pub const DatasetItem = dataset.Item;
pub const GoldenEntry = golden.Entry;
pub const Observation = bless.Observation;
pub const Outcome = report.Outcome;
pub const Report = report.Report;

test {
    std.testing.refAllDecls(@import("dataset.zig"));
    std.testing.refAllDecls(@import("golden.zig"));
    std.testing.refAllDecls(@import("bless.zig"));
    std.testing.refAllDecls(@import("report.zig"));
}
