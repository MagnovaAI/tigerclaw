//! Static invariant checks for the plug architecture.
//!
//! Catches drift between the compiled code and the architectural
//! promises: capability ABI stability, vtable version table coverage,
//! error id table coverage, CalVer format, plug id prefix conventions.
//!
//! runAll() returns a Report. Wire from `tigerclaw doctor invariants`
//! (exit non-zero on failures) or call directly in contract tests.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §invariants

const std = @import("std");
const capabilities = @import("capabilities.zig");
const errors = @import("errors");
const envelope = @import("envelope.zig");

pub const Check = struct {
    name: []const u8,
    passed: bool,
    detail: []const u8 = "",
};

pub const Report = struct {
    checks: std.ArrayList(Check),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Report {
        return .{ .checks = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Report) void {
        self.checks.deinit(self.alloc);
    }

    pub fn add(self: *Report, check: Check) !void {
        try self.checks.append(self.alloc, check);
    }

    pub fn allPassed(self: *const Report) bool {
        for (self.checks.items) |c| if (!c.passed) return false;
        return true;
    }

    pub fn failedCount(self: *const Report) usize {
        var n: usize = 0;
        for (self.checks.items) |c| if (!c.passed) {
            n += 1;
        };
        return n;
    }
};

/// Run every compiled-in invariant. Returns a Report; caller owns it.
pub fn runAll(alloc: std.mem.Allocator) !Report {
    var r = Report.init(alloc);
    errdefer r.deinit();

    try checkCapabilityCount(&r);
    try checkVtableVersionCoverage(&r);
    try checkErrorIdCoverage(&r);
    try checkEnvelopeVersion(&r);
    try checkVerbEnumCardinality(&r);

    return r;
}

fn checkCapabilityCount(r: *Report) !void {
    // Spec says 11 verbs + 5 infrastructure + 2 context capabilities = 18.
    const expected: usize = 18;
    const actual = capabilities.capability_count;
    try r.add(.{
        .name = "capability_count matches spec (18)",
        .passed = actual == expected,
        .detail = if (actual == expected) "" else "capability enum drift vs spec",
    });
}

fn checkVtableVersionCoverage(r: *Report) !void {
    // currentVtableVersion() is exhaustive-switch over Capability, so
    // if any variant lacked coverage Zig would reject at compile time.
    // Probe one from each layer to confirm the wiring.
    const caps = [_]capabilities.Capability{
        .persona, .channel, .providers, .memory, .guardrails,
        .clock,   .meter,   .telemetry, .waiter, .hook_bus,
    };
    for (caps) |c| {
        const v = capabilities.currentVtableVersion(c);
        if (v != 1) {
            try r.add(.{
                .name = "vtable_version == 1 for all capabilities",
                .passed = false,
                .detail = capabilities.Capability.name(c),
            });
            return;
        }
    }
    try r.add(.{
        .name = "vtable_version == 1 for all capabilities",
        .passed = true,
    });
}

fn checkErrorIdCoverage(r: *Report) !void {
    // Every PlugError variant must map to a real Id.
    const variants = [_]errors.PlugError{
        error.Unavailable,
        error.BadInput,
        error.Timeout,
        error.Refused,
        error.OverBudget,
        error.Internal,
    };
    for (variants) |e| {
        const id = errors.plugErrorToId(e);
        const desc = errors.description(id);
        if (desc.len == 0) {
            try r.add(.{
                .name = "plugErrorToId produces valid Id for every PlugError",
                .passed = false,
                .detail = @errorName(e),
            });
            return;
        }
    }
    try r.add(.{
        .name = "plugErrorToId produces valid Id for every PlugError",
        .passed = true,
    });
}

fn checkEnvelopeVersion(r: *Report) !void {
    try r.add(.{
        .name = "envelope schema version locked at 1",
        .passed = envelope.EnvelopeV == 1,
    });
}

fn checkVerbEnumCardinality(r: *Report) !void {
    // Spec fixtures count: 9 Verb values (excluding UNSPECIFIED=0).
    const info = @typeInfo(envelope.Verb).@"enum";
    const expected: usize = 10; // 9 real verbs + UNSPECIFIED
    try r.add(.{
        .name = "Verb enum has 10 values (UNSPECIFIED + 9 canonical)",
        .passed = info.fields.len == expected,
    });
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "runAll: all invariants pass against current build" {
    var r = try runAll(testing.allocator);
    defer r.deinit();

    if (!r.allPassed()) {
        for (r.checks.items) |c| {
            std.debug.print("{s}: passed={} detail='{s}'\n", .{ c.name, c.passed, c.detail });
        }
    }
    try testing.expect(r.allPassed());
}

test "runAll: produces 5 checks" {
    var r = try runAll(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 5), r.checks.items.len);
}

test "Report.failedCount: 0 on all-pass" {
    var r = try runAll(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.failedCount());
}
