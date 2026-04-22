//! Channels subsystem — front door.
//!
//! Re-exports the channel abstraction. Concrete adapters (Telegram first)
//! land in follow-up commits under this directory.

const std = @import("std");

pub const spec = @import("spec.zig");

test {
    std.testing.refAllDecls(@import("spec.zig"));
}
