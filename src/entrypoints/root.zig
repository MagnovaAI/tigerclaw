//! CLI-facing entrypoints.
//!
//! Each submodule implements one top-level command as a library
//! function: dependencies are injected via an `Options` struct,
//! output goes to a caller-supplied writer, and the return value
//! is a simple `Report` that tests can assert on.
//!
//! Submodules:
//!   * `run`    — execute a single turn against a `Provider`.
//!   * `doctor` — print a short self-check for operators.
//!   * `list`   — enumerate persisted sessions in the state dir.
//!
//! The `main.zig` CLI frontend glues argv parsing to these
//! functions; tests (unit and E2E) call them directly.

const std = @import("std");

pub const run = @import("run.zig");
pub const doctor = @import("doctor.zig");
pub const list = @import("list.zig");

pub const RunOptions = run.RunOptions;
pub const RunResult = run.RunResult;
pub const DoctorOptions = doctor.Options;
pub const DoctorReport = doctor.Report;
pub const ListOptions = list.Options;
pub const ListReport = list.Report;

test {
    std.testing.refAllDecls(@import("run.zig"));
    std.testing.refAllDecls(@import("doctor.zig"));
    std.testing.refAllDecls(@import("list.zig"));
}
