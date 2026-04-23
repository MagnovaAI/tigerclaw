//! Memory subsystem — front door.
//!
//! Re-exports the session-store abstraction. Concrete backends land in
//! follow-up work under `extensions/tigerclaw-memory/`.

const std = @import("std");

// `spec` is its own named module so extension code (in a separate
// module graph) can import it via `@import("memory_spec")` without
// the file being claimed by two modules at once.
pub const spec = @import("memory_spec");

test {
    std.testing.refAllDecls(@import("memory_spec"));
}
