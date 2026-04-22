//! Bench subsystem: scenario adapter, runner, scheduler, metrics,
//! aggregator, reporter, compare. Each file is independently
//! testable; the root exports the minimum surface a CLI or CI
//! script needs.

const std = @import("std");

pub const scenario = @import("scenario.zig");
pub const runner = @import("runner.zig");
pub const scheduler = @import("scheduler.zig");
pub const metrics = @import("metrics.zig");
pub const aggregator = @import("aggregator.zig");
pub const reporter = @import("reporter.zig");
pub const compare = @import("compare.zig");

pub const Case = scenario.Case;
pub const Executor = runner.Executor;
pub const CaseMetric = metrics.CaseMetric;
pub const RunSummary = metrics.RunSummary;
pub const Delta = compare.Delta;

test {
    std.testing.refAllDecls(@import("scenario.zig"));
    std.testing.refAllDecls(@import("runner.zig"));
    std.testing.refAllDecls(@import("scheduler.zig"));
    std.testing.refAllDecls(@import("metrics.zig"));
    std.testing.refAllDecls(@import("aggregator.zig"));
    std.testing.refAllDecls(@import("reporter.zig"));
    std.testing.refAllDecls(@import("compare.zig"));
}
