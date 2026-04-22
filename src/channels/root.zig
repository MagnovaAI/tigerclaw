//! Channels subsystem — front door.
//!
//! Re-exports the channel abstraction. Concrete adapters (Telegram first)
//! land in follow-up commits under this directory.

const std = @import("std");
const build_options = @import("build_options");

pub const spec = @import("spec.zig");
pub const dispatch = @import("dispatch.zig");
pub const router = @import("router.zig");
pub const outbox = @import("outbox.zig");

/// Comptime-gated re-export of the Telegram extension. Replaced by
/// an empty struct when the extension was disabled at build time so
/// callers can `@hasDecl`-check without a runtime gate.
pub const telegram = if (build_options.enable_telegram)
    @import("channel_telegram")
else
    struct {};

test {
    std.testing.refAllDecls(@import("spec.zig"));
    std.testing.refAllDecls(@import("dispatch.zig"));
    std.testing.refAllDecls(@import("router.zig"));
    std.testing.refAllDecls(@import("outbox.zig"));
}
