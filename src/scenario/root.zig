//! Scenario subsystem: loader for the v3 scenario format.
//!
//! Toy scenarios ship under `scenarios/` at repo root so the
//! bench/eval subsystems have something real to run against.

const std = @import("std");

pub const loader = @import("loader.zig");
pub const Scenario = loader.Scenario;
pub const schema_version = loader.schema_version;

test {
    std.testing.refAllDecls(@import("loader.zig"));
}
