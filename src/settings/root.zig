//! Layered settings subsystem. Modules land here incrementally:
//! - schema: the `Settings` struct.
//! - validation: field-level checks.
//! - managed_path: resolves the config-file location.
//! Loader, env overrides, change detection, and secrets follow in later
//! commits.

const std = @import("std");

pub const schema = @import("schema.zig");
pub const validation = @import("validation.zig");
pub const managed_path = @import("managed_path.zig");

pub const Settings = schema.Settings;
pub const LogLevel = schema.LogLevel;
pub const Mode = schema.Mode;

test {
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("validation.zig"));
    std.testing.refAllDecls(@import("managed_path.zig"));
}
