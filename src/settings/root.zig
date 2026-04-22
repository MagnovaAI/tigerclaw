//! Layered settings subsystem. Modules land here incrementally:
//! - schema: the `Settings` struct.
//! - validation: field-level checks.
//! - managed_path: resolves the config-file location.
//! Loader, env overrides, change detection, and secrets follow in later
//! commits.

const std = @import("std");

pub const schema = @import("schema.zig");
pub const agents = @import("agents.zig");
pub const validation = @import("validation.zig");
pub const managed_path = @import("managed_path.zig");
pub const env_overrides = @import("env_overrides.zig");
pub const cache = @import("cache.zig");
pub const apply_change = @import("apply_change.zig");
pub const loader = @import("settings.zig");
pub const internal_writes = @import("internal_writes.zig");
pub const change_detector = @import("change_detector.zig");
pub const secrets = @import("secrets.zig");
pub const mdm = @import("mdm.zig");

pub const Settings = schema.Settings;
pub const LogLevel = schema.LogLevel;
pub const Mode = schema.Mode;
pub const Cache = cache.Cache;

test {
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("agents.zig"));
    std.testing.refAllDecls(@import("validation.zig"));
    std.testing.refAllDecls(@import("managed_path.zig"));
    std.testing.refAllDecls(@import("env_overrides.zig"));
    std.testing.refAllDecls(@import("cache.zig"));
    std.testing.refAllDecls(@import("apply_change.zig"));
    std.testing.refAllDecls(@import("settings.zig"));
    std.testing.refAllDecls(@import("internal_writes.zig"));
    std.testing.refAllDecls(@import("change_detector.zig"));
    std.testing.refAllDecls(@import("secrets.zig"));
    std.testing.refAllDecls(@import("mdm.zig"));
}
