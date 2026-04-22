//! Canonical error taxonomy.
//!
//! Every subsystem maps its failure modes onto an `Id` here. Ids are stable
//! identifiers used in logs, traces, and user-facing messages — renaming one
//! is a breaking change. To add a variant, append; never reorder. To retire a
//! variant, mark it `.deprecated` in the `descriptions` table and leave the
//! enum slot reserved.

const std = @import("std");

pub const Id = enum {
    // Core primitives
    invalid_argument,
    not_found,
    permission_denied,
    timed_out,
    cancelled,
    unavailable,
    // I/O
    io_read,
    io_write,
    io_closed,
    // Parse / schema
    parse_failure,
    schema_mismatch,
    version_mismatch,
    // Budget / cost
    budget_exhausted,
    rate_limited,
    // Harness
    mode_forbidden,
    interrupt_requested,
};

pub fn name(id: Id) []const u8 {
    return @tagName(id);
}

pub fn description(id: Id) []const u8 {
    return switch (id) {
        .invalid_argument => "argument failed validation",
        .not_found => "requested resource does not exist",
        .permission_denied => "policy refused the operation",
        .timed_out => "operation exceeded its deadline",
        .cancelled => "operation was cancelled",
        .unavailable => "dependency is unreachable",
        .io_read => "read from a stream failed",
        .io_write => "write to a stream failed",
        .io_closed => "stream was already closed",
        .parse_failure => "input did not match its grammar",
        .schema_mismatch => "data shape did not match schema",
        .version_mismatch => "on-disk version is incompatible",
        .budget_exhausted => "cost ledger has no remaining budget",
        .rate_limited => "provider rejected the request as rate-limited",
        .mode_forbidden => "current harness mode forbids this operation",
        .interrupt_requested => "caller asked the loop to stop",
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "name: returns the enum tag as a string" {
    try testing.expectEqualStrings("invalid_argument", name(.invalid_argument));
    try testing.expectEqualStrings("budget_exhausted", name(.budget_exhausted));
}

test "description: every variant has a non-empty description" {
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @field(Id, f.name);
        const d = description(id);
        try testing.expect(d.len > 0);
    }
}

test "stability: canonical ids are spelled as expected" {
    // This test is a trip-wire. Renames here are breaking changes and must
    // be accompanied by a CHANGELOG entry.
    const expected = [_][]const u8{
        "invalid_argument",
        "not_found",
        "permission_denied",
        "timed_out",
        "cancelled",
        "unavailable",
        "io_read",
        "io_write",
        "io_closed",
        "parse_failure",
        "schema_mismatch",
        "version_mismatch",
        "budget_exhausted",
        "rate_limited",
        "mode_forbidden",
        "interrupt_requested",
    };
    const fields = @typeInfo(Id).@"enum".fields;
    try testing.expectEqual(expected.len, fields.len);
    inline for (fields, 0..) |f, i| {
        try testing.expectEqualStrings(expected[i], f.name);
    }
}
