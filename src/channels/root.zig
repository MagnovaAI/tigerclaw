//! Channels subsystem — front door.
//!
//! Re-exports the channel abstraction. Concrete adapters (Telegram first)
//! land in follow-up commits under this directory.

const std = @import("std");
const build_options = @import("build_options");

// `spec` is its own named module so extension code (in a separate
// module graph) can import it via `@import("channels_spec")` without
// the file being claimed by two modules at once.
pub const spec = @import("channels_spec");
pub const dispatch = @import("dispatch.zig");
pub const router = @import("router.zig");
pub const outbox = @import("outbox.zig");
pub const manager = @import("manager.zig");
pub const allowlist = @import("allowlist.zig");
pub const startup = @import("startup.zig");

/// Comptime-gated re-export of the Telegram extension. Replaced by
/// an empty struct when the extension was disabled at build time so
/// callers can `@hasDecl`-check without a runtime gate.
pub const telegram = if (build_options.enable_telegram)
    @import("channel_telegram")
else
    struct {};

test {
    std.testing.refAllDecls(@import("channels_spec"));
    std.testing.refAllDecls(@import("dispatch.zig"));
    std.testing.refAllDecls(@import("router.zig"));
    std.testing.refAllDecls(@import("outbox.zig"));
    std.testing.refAllDecls(@import("manager.zig"));
    std.testing.refAllDecls(@import("allowlist.zig"));
    std.testing.refAllDecls(@import("startup.zig"));
}
