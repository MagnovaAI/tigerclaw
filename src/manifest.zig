//! Extension manifest — declarative metadata per plug.
//!
//! A Manifest is the identity card for an extension: what it is, what
//! capabilities it provides, what it needs, what it conflicts with,
//! and which slot it fills. The registry consults manifests when
//! building snapshots to enforce slot rules and dependency order.
//!
//! Dependencies are declared against CAPABILITIES, not other
//! extensions — this keeps swaps loose-coupled: whatever plug is
//! active for a capability satisfies the dependency.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.manifest

const std = @import("std");
const capabilities = @import("capabilities.zig");
const registry = @import("registry.zig");

const Capability = capabilities.Capability;
const Slot = registry.Slot;

/// Platform constraint; checked at registration time. Plugs that don't
/// match the host platform are skipped during lifecycle start.
pub const Platform = struct {
    /// `null` means: run on any OS.
    os: ?std.Target.Os.Tag = null,
    /// `null` means: run on any arch.
    arch: ?std.Target.Cpu.Arch = null,
    /// `null` means: run under any runtime mode.
    runtime: ?RuntimeMode = null,

    pub const any: Platform = .{};
};

pub const RuntimeMode = enum { native, docker, wasm };

/// Dependency kind between a plug and a capability.
pub const DepKind = enum {
    /// Hard requirement. Registration fails if capability is missing.
    requires,
    /// Soft preference. Used for start-order tie-breaks.
    prefers,
    /// Explicit incompatibility. Registration fails if both active.
    conflicts,
};

/// A single capability dependency edge.
pub const Dep = struct {
    capability: Capability,
    kind: DepKind,
};

/// Declarative per-plug metadata. Compiled into the plug's extension
/// module and passed to the registry at start time.
pub const Manifest = struct {
    /// Unique plug id (singular prefix, e.g. "provider-anthropic",
    /// "channel-discord", "guardrail-access-allowlist").
    id: []const u8,

    /// CalVer version string, zero-padded (e.g. "2026.04.23").
    version: []const u8,

    /// Capabilities this plug provides.
    provides: []const Capability,

    /// Capability dependencies. Ordering irrelevant; semantics defined
    /// by each Dep.kind.
    deps: []const Dep,

    /// Slot kind for this plug's primary capability. Exclusive slots
    /// allow at most one active plug per capability; shared allows N.
    slot: Slot,

    /// Optional JSON-schema path (relative to repo root) describing
    /// the plug's config block. Empty string = no schema.
    config_schema: []const u8 = "",

    /// Integer hint for topological tie-breaks; smaller starts earlier.
    /// Default 0.
    start_order: i32 = 0,

    /// Platform constraints; default = any.
    platform: Platform = Platform.any,

    /// True if the current target OS/arch satisfies `platform`.
    pub fn matchesPlatform(self: Manifest) bool {
        const host = @import("builtin").target;
        if (self.platform.os) |required_os| {
            if (required_os != host.os.tag) return false;
        }
        if (self.platform.arch) |required_arch| {
            if (required_arch != host.cpu.arch) return false;
        }
        // runtime mode check: we don't detect mode at compile-time yet;
        // leave null to mean "any". Runtime detection lands with
        // supervisor plug in Phase 2/3.
        return true;
    }

    /// Convenience: does this manifest declare a `requires` edge on the
    /// given capability?
    pub fn requires(self: Manifest, cap: Capability) bool {
        for (self.deps) |d| {
            if (d.kind == .requires and d.capability == cap) return true;
        }
        return false;
    }

    /// Convenience: does this manifest declare a `conflicts` edge on
    /// the given capability?
    pub fn conflictsWith(self: Manifest, cap: Capability) bool {
        for (self.deps) |d| {
            if (d.kind == .conflicts and d.capability == cap) return true;
        }
        return false;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Manifest: requires helper returns true only for required deps" {
    const m = Manifest{
        .id = "provider-anthropic",
        .version = "2026.04.23",
        .provides = &[_]Capability{.providers},
        .deps = &[_]Dep{
            .{ .capability = .clock, .kind = .requires },
            .{ .capability = .telemetry, .kind = .prefers },
            .{ .capability = .meter, .kind = .requires },
        },
        .slot = .exclusive_with_fallback,
    };
    try testing.expect(m.requires(.clock));
    try testing.expect(m.requires(.meter));
    try testing.expect(!m.requires(.telemetry)); // prefers, not requires
    try testing.expect(!m.requires(.persona));
}

test "Manifest: conflictsWith helper" {
    const m = Manifest{
        .id = "channel-telegram",
        .version = "2026.04.23",
        .provides = &[_]Capability{.channel},
        .deps = &[_]Dep{
            .{ .capability = .persona, .kind = .conflicts },
        },
        .slot = .shared,
    };
    try testing.expect(m.conflictsWith(.persona));
    try testing.expect(!m.conflictsWith(.clock));
}

test "Manifest: matchesPlatform accepts any when unset" {
    const m = Manifest{
        .id = "plug-any",
        .version = "2026.04.23",
        .provides = &[_]Capability{.memory},
        .deps = &.{},
        .slot = .shared,
    };
    try testing.expect(m.matchesPlatform());
}

test "Manifest: matchesPlatform rejects wrong OS" {
    const wrong_os: std.Target.Os.Tag = switch (@import("builtin").target.os.tag) {
        .linux => .windows,
        else => .linux,
    };
    const m = Manifest{
        .id = "plug-specific-os",
        .version = "2026.04.23",
        .provides = &[_]Capability{.memory},
        .deps = &.{},
        .slot = .shared,
        .platform = .{ .os = wrong_os },
    };
    try testing.expect(!m.matchesPlatform());
}
