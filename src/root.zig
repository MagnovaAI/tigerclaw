//! tigerclaw — library root.
//!
//! Re-exports the public surface of the runtime. Subsystems are added here
//! as they land. Dependency direction flows inward toward primitives
//! (log, clock, determinism, errors); subsystems must not import across
//! each other.

pub const cli = @import("cli.zig");
pub const clock = @import("clock.zig");
pub const determinism = @import("determinism.zig");
pub const errors = @import("errors.zig");
pub const globals = @import("globals.zig");
pub const log = @import("log.zig");
pub const version = @import("version.zig");
