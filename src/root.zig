//! tigerclaw — library root.
//!
//! Re-exports the public surface of the runtime. Subsystems are added here
//! as they land. Dependency direction flows inward toward primitives
//! (log, clock, determinism, errors); subsystems must not import across
//! each other.

pub const cli = @import("cli.zig");
