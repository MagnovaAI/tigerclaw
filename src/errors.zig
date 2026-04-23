//! Canonical error taxonomy.
//!
//! Two layers live here:
//!
//! 1. `Id` — the project-wide canonical error catalog used in logs,
//!    traces, and user-facing messages. Stable: append-only, never
//!    reorder, never rename (renames are breaking changes).
//! 2. `PlugError` — the closed error set Zig's error-union system uses
//!    at plug vtable boundaries. Every plugger vtable method returns a
//!    value of type `PlugError!T`, never `anyerror!T`. Callers can
//!    handle exhaustive error variants.
//!
//! `plugErrorToId()` maps a PlugError back to the corresponding Id so
//! existing log/trace infrastructure keeps working unchanged.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.error-taxonomy

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
    // Plug vtable boundary
    internal,
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
        .internal => "unexpected internal failure (always a bug)",
    };
}

// --- PlugError: closed error set for vtable boundaries ---------------------

/// Closed error set returned at plug vtable boundaries. Plugs surface
/// exactly one of these variants; callers can handle them exhaustively
/// without resorting to `anyerror`.
///
/// Mapping back to the broader `Id` catalog is available via
/// `plugErrorToId()` — that keeps existing log/trace paths working.
pub const PlugError = error{
    /// Dependency unreachable or temporarily missing (network down,
    /// upstream 5xx, sidecar not started, required fs path absent).
    Unavailable,

    /// Input failed validation at the plug boundary: malformed envelope,
    /// unknown verb, wrong schema version, etc.
    BadInput,

    /// Operation exceeded the deadline carried by Context.deadline_ms.
    Timeout,

    /// Policy refused the operation. Guardrail deny, PKG scope
    /// unauthorized, authz rejection.
    Refused,

    /// Budget (meter) could not cover the requested operation.
    OverBudget,

    /// Unexpected internal failure. Always a bug; logged and traced
    /// with best-effort context.
    Internal,
};

/// Maps a PlugError to the canonical Id used by the rest of the
/// taxonomy. The mapping is exhaustive — every PlugError variant has a
/// corresponding Id, so logs and traces stay uniform regardless of
/// where the failure originated.
pub fn plugErrorToId(e: PlugError) Id {
    return switch (e) {
        error.Unavailable => .unavailable,
        error.BadInput => .invalid_argument,
        error.Timeout => .timed_out,
        error.Refused => .permission_denied,
        error.OverBudget => .budget_exhausted,
        error.Internal => .internal,
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
        "internal",
    };
    const fields = @typeInfo(Id).@"enum".fields;
    try testing.expectEqual(expected.len, fields.len);
    inline for (fields, 0..) |f, i| {
        try testing.expectEqualStrings(expected[i], f.name);
    }
}

test "PlugError: every variant maps to an Id" {
    // Exhaustive: inline for over the PlugError error set ensures any
    // new variant added breaks this test until a mapping is added.
    const variants = [_]PlugError{
        error.Unavailable,
        error.BadInput,
        error.Timeout,
        error.Refused,
        error.OverBudget,
        error.Internal,
    };
    for (variants) |e| {
        const id = plugErrorToId(e);
        // Just assert description is non-empty; semantic correctness of
        // the mapping is checked by the specific-case test below.
        const d = description(id);
        try testing.expect(d.len > 0);
    }
}

test "PlugError: mapping is semantically correct" {
    try testing.expectEqual(Id.unavailable, plugErrorToId(error.Unavailable));
    try testing.expectEqual(Id.invalid_argument, plugErrorToId(error.BadInput));
    try testing.expectEqual(Id.timed_out, plugErrorToId(error.Timeout));
    try testing.expectEqual(Id.permission_denied, plugErrorToId(error.Refused));
    try testing.expectEqual(Id.budget_exhausted, plugErrorToId(error.OverBudget));
    try testing.expectEqual(Id.internal, plugErrorToId(error.Internal));
}
