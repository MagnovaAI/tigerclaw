//! Closed capability enum + vtable version constants.
//!
//! Every pluggable slot in the runtime maps to one Capability variant.
//! The enum is append-only: adding a value is a code change, on purpose.
//! Never reorder or remove — existing registrations reference by integer
//! tag across snapshot swaps, and external tooling (manifests, invariant
//! validator) treats the integer ordering as a stable contract.
//!
//! Vtable versions are bumped when the function-pointer shape of the
//! plugger's vtable changes in a breaking way. Plugs declaring an older
//! version are refused at registration time.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.capability-enum

const std = @import("std");

/// Every capability slot known to the runtime. Order is stable; never
/// reorder existing values. Append only.
pub const Capability = enum(u8) {
    // Identity
    persona,
    pairing,

    // Perception + Action
    channel,

    // Cognition
    providers,
    planner,

    // Continuity
    memory,
    supervisor,
    scheduler,

    // Enforcement
    guardrails,

    // Tool invocation
    tools,

    // Attestation
    auditor,

    // Cross-cutting infrastructure (not verbs but registered the same way)
    clock,
    meter,
    telemetry,
    waiter,
    hook_bus,

    // Context
    context_engine,
    context_contributor,

    /// Stable integer tag across releases. Do not change values of
    /// existing variants — add new ones at the end.
    pub fn tag(self: Capability) u8 {
        return @intFromEnum(self);
    }

    /// Human-readable name; matches the spec's plugger names (plural for
    /// the ones that are plural, singular for singletons).
    pub fn name(self: Capability) []const u8 {
        return switch (self) {
            .persona => "persona",
            .pairing => "pairing",
            .channel => "channel",
            .providers => "providers",
            .planner => "planner",
            .memory => "memory",
            .supervisor => "supervisor",
            .scheduler => "scheduler",
            .guardrails => "guardrails",
            .tools => "tools",
            .auditor => "auditor",
            .clock => "clock",
            .meter => "meter",
            .telemetry => "telemetry",
            .waiter => "waiter",
            .hook_bus => "hook_bus",
            .context_engine => "context_engine",
            .context_contributor => "context_contributor",
        };
    }
};

/// Vtable version per capability. Bumped when the vtable's function-
/// pointer signatures change in a breaking way. Registry refuses to
/// activate a plug whose declared vtable version doesn't match.
pub const vtable_version = struct {
    pub const persona: u16 = 1;
    pub const pairing: u16 = 1;
    pub const channel: u16 = 1;
    pub const providers: u16 = 1;
    pub const planner: u16 = 1;
    pub const memory: u16 = 1;
    pub const supervisor: u16 = 1;
    pub const scheduler: u16 = 1;
    pub const guardrails: u16 = 1;
    pub const tools: u16 = 1;
    pub const auditor: u16 = 1;
    pub const clock: u16 = 1;
    pub const meter: u16 = 1;
    pub const telemetry: u16 = 1;
    pub const waiter: u16 = 1;
    pub const hook_bus: u16 = 1;
    pub const context_engine: u16 = 1;
    pub const context_contributor: u16 = 1;
};

/// Returns the current vtable version for the given capability. Used by
/// the registry + manifest verification code.
pub fn currentVtableVersion(cap: Capability) u16 {
    return switch (cap) {
        .persona => vtable_version.persona,
        .pairing => vtable_version.pairing,
        .channel => vtable_version.channel,
        .providers => vtable_version.providers,
        .planner => vtable_version.planner,
        .memory => vtable_version.memory,
        .supervisor => vtable_version.supervisor,
        .scheduler => vtable_version.scheduler,
        .guardrails => vtable_version.guardrails,
        .tools => vtable_version.tools,
        .auditor => vtable_version.auditor,
        .clock => vtable_version.clock,
        .meter => vtable_version.meter,
        .telemetry => vtable_version.telemetry,
        .waiter => vtable_version.waiter,
        .hook_bus => vtable_version.hook_bus,
        .context_engine => vtable_version.context_engine,
        .context_contributor => vtable_version.context_contributor,
    };
}

/// Count of capabilities known at compile time; useful for registry
/// internal tables indexed by capability tag.
pub const capability_count: usize = blk: {
    const info = @typeInfo(Capability).@"enum";
    break :blk info.fields.len;
};

test "tag values are stable and append-only" {
    // These integer values are an ABI contract. Do not change. Adding
    // new capabilities appends; never reorder.
    try std.testing.expectEqual(@as(u8, 0), Capability.persona.tag());
    try std.testing.expectEqual(@as(u8, 1), Capability.pairing.tag());
    try std.testing.expectEqual(@as(u8, 2), Capability.channel.tag());
    try std.testing.expectEqual(@as(u8, 3), Capability.providers.tag());
    try std.testing.expectEqual(@as(u8, 4), Capability.planner.tag());
    try std.testing.expectEqual(@as(u8, 5), Capability.memory.tag());
    try std.testing.expectEqual(@as(u8, 6), Capability.supervisor.tag());
    try std.testing.expectEqual(@as(u8, 7), Capability.scheduler.tag());
    try std.testing.expectEqual(@as(u8, 8), Capability.guardrails.tag());
    try std.testing.expectEqual(@as(u8, 9), Capability.tools.tag());
    try std.testing.expectEqual(@as(u8, 10), Capability.auditor.tag());
    try std.testing.expectEqual(@as(u8, 11), Capability.clock.tag());
    try std.testing.expectEqual(@as(u8, 12), Capability.meter.tag());
    try std.testing.expectEqual(@as(u8, 13), Capability.telemetry.tag());
    try std.testing.expectEqual(@as(u8, 14), Capability.waiter.tag());
    try std.testing.expectEqual(@as(u8, 15), Capability.hook_bus.tag());
    try std.testing.expectEqual(@as(u8, 16), Capability.context_engine.tag());
    try std.testing.expectEqual(@as(u8, 17), Capability.context_contributor.tag());
}

test "capability_count matches enum field count" {
    try std.testing.expectEqual(@as(usize, 18), capability_count);
}

test "name returns canonical plugger name" {
    try std.testing.expectEqualStrings("persona", Capability.persona.name());
    try std.testing.expectEqualStrings("guardrails", Capability.guardrails.name());
    try std.testing.expectEqualStrings("hook_bus", Capability.hook_bus.name());
}

test "currentVtableVersion covers every capability" {
    // Exhaustive; missing a variant would fail to compile due to the
    // switch statement. This test just proves every variant returns
    // the expected v1 default.
    inline for (std.meta.fields(Capability)) |f| {
        const cap: Capability = @enumFromInt(f.value);
        const v = currentVtableVersion(cap);
        try std.testing.expectEqual(@as(u16, 1), v);
    }
}
