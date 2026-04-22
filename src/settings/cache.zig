//! In-memory cache for the resolved `Settings` value.
//!
//! The loader installs a snapshot here; subsystems read from it. The
//! cache is intentionally dumb — no locking, no copy-on-write — because
//! settings mutate only through `apply_change.zig`, which serialises
//! updates via the harness.

const std = @import("std");
const schema = @import("schema.zig");
const Settings = schema.Settings;

pub const Cache = struct {
    current: Settings = .{},
    generation: u64 = 0,

    pub fn init() Cache {
        return .{};
    }

    pub fn get(self: *const Cache) Settings {
        return self.current;
    }

    pub fn install(self: *Cache, next: Settings) void {
        self.current = next;
        self.generation += 1;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Cache.init: starts at generation 0 with defaults" {
    const c = Cache.init();
    try testing.expectEqual(@as(u64, 0), c.generation);
    try testing.expectEqual(Settings{}, c.get());
}

test "Cache.install: swaps the current value and bumps generation" {
    var c = Cache.init();
    c.install(.{ .log_level = .warn, .max_tool_iterations = 5 });
    try testing.expectEqual(@as(u64, 1), c.generation);
    try testing.expectEqual(schema.LogLevel.warn, c.get().log_level);
    try testing.expectEqual(@as(u32, 5), c.get().max_tool_iterations);
}

test "Cache.install: each call increments generation" {
    var c = Cache.init();
    c.install(.{});
    c.install(.{});
    c.install(.{});
    try testing.expectEqual(@as(u64, 3), c.generation);
}
