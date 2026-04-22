//! Named magic numbers and static strings, grouped by audience.

const std = @import("std");

pub const api_limits = @import("api_limits.zig");
pub const error_ids = @import("error_ids.zig");
pub const messages = @import("messages.zig");
pub const defaults = @import("defaults.zig");

test {
    std.testing.refAllDecls(@import("api_limits.zig"));
    std.testing.refAllDecls(@import("error_ids.zig"));
    std.testing.refAllDecls(@import("messages.zig"));
    std.testing.refAllDecls(@import("defaults.zig"));
}
