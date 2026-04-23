//! Canonical identifier strings for the `errors.Id` enum.
//!
//! These are the byte-stable names emitted in traces, logs, and tool
//! results. The taxonomy lives in `src/errors.zig`; this module mirrors
//! it as strings so tools that don't want to depend on the enum type
//! (trace writers, JSON encoders) can still reference canonical names.
//!
//! A mismatch between this list and the enum fails at compile time — see
//! the test at the bottom.

const std = @import("std");
const errors = @import("../errors.zig");

pub const invalid_argument = "invalid_argument";
pub const not_found = "not_found";
pub const permission_denied = "permission_denied";
pub const timed_out = "timed_out";
pub const cancelled = "cancelled";
pub const unavailable = "unavailable";
pub const io_read = "io_read";
pub const io_write = "io_write";
pub const io_closed = "io_closed";
pub const parse_failure = "parse_failure";
pub const schema_mismatch = "schema_mismatch";
pub const version_mismatch = "version_mismatch";
pub const budget_exhausted = "budget_exhausted";
pub const rate_limited = "rate_limited";
pub const mode_forbidden = "mode_forbidden";
pub const interrupt_requested = "interrupt_requested";
pub const internal = "internal";

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "error_ids mirrors errors.Id exactly" {
    const fields = @typeInfo(errors.Id).@"enum".fields;
    inline for (fields) |f| {
        const here = @field(@This(), f.name);
        try testing.expectEqualStrings(f.name, here);
    }
}
