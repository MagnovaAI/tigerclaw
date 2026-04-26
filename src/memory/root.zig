//! Memory subsystem — front door.
//!
//! Re-exports the session-store abstraction (`spec`), the agent-facing
//! provider vtable, the built-in provider, and the manager that holds
//! built-in plus at most one external provider. Concrete storage
//! backends live under `extensions/` and are gated at build time so
//! the core stays small.

const std = @import("std");
const build_options = @import("build_options");

// `spec` is its own named module so extension code (in a separate
// module graph) can import it via `@import("memory_spec")` without
// the file being claimed by two modules at once.
pub const spec = @import("memory_spec");

pub const provider = @import("provider.zig");
pub const builtin = @import("builtin.zig");
pub const manager = @import("manager.zig");

pub const Provider = provider.Provider;
pub const MemoryError = provider.MemoryError;
pub const Builtin = builtin.Builtin;
pub const Manager = manager.Manager;

/// Comptime-gated re-export of the SQLite-backed default backend.
/// Replaced by an empty struct when disabled so callers can `@hasDecl`-
/// check without a runtime gate.
pub const tigerclaw = if (build_options.enable_memory)
    @import("memory_tigerclaw")
else
    struct {};

test {
    std.testing.refAllDecls(@import("memory_spec"));
    std.testing.refAllDecls(@This());
}
