//! Small, cross-cutting utilities.
//!
//! This module is the home for primitives that do not belong to
//! any one subsystem but are too small to justify their own
//! top-level directory. Keep the bar high: a file lands here only
//! if at least two subsystems want it.

const std = @import("std");

pub const diagnostics = @import("diagnostics.zig");

pub const DiagnosticsBuffer = diagnostics.DiagnosticsBuffer;

test {
    std.testing.refAllDecls(@import("diagnostics.zig"));
}
