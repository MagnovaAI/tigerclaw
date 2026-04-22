//! Default values used when config is silent.
//!
//! Every `settings/schema.zig` field must have a corresponding default
//! here, so the runtime can start with an empty config file. Values that
//! depend on provider or runtime mode live in their own modules.

const std = @import("std");

/// Maximum number of tool-call iterations in a single turn before the
/// agent loop gives up.
pub const max_tool_iterations: u32 = 1_000;

/// Maximum number of messages retained in-memory before compaction fires.
pub const max_history_messages: u32 = 100;

/// Default minimum log level. Config can raise or lower it.
pub const min_log_level_name: []const u8 = "info";

/// Default monthly cost cap in cents. Zero means "no cap".
pub const monthly_budget_cents: u64 = 0;

/// Default harness mode slug.
pub const mode_slug: []const u8 = "run";

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "defaults: tunables are non-zero where it matters" {
    try testing.expect(max_tool_iterations > 0);
    try testing.expect(max_history_messages > 0);
}

test "defaults: mode_slug is one of the pinned harness modes" {
    const valid = [_][]const u8{ "run", "bench", "replay", "eval" };
    var found = false;
    for (valid) |v| {
        if (std.mem.eql(u8, v, mode_slug)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "defaults: min_log_level_name is one of debug|info|warn|error" {
    const valid = [_][]const u8{ "debug", "info", "warn", "error" };
    var found = false;
    for (valid) |v| {
        if (std.mem.eql(u8, v, min_log_level_name)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
