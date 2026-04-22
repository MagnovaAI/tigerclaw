//! Integration: a config file + env pair flow through the loader into a
//! cache, and an apply_change patch mutates the cache without tripping
//! validation.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const settings = tigerclaw.settings;

const testing = std.testing;
const MapLookup = settings.env_overrides.MapLookup;
const prefix = settings.env_overrides.prefix;

test "loader + cache: env beats file, cache tracks generation" {
    const cfg = "{\"log_level\":\"info\",\"mode\":\"run\",\"max_tool_iterations\":100}";
    var env = MapLookup{ .entries = &.{
        .{ .name = prefix ++ "LOG_LEVEL", .value = "debug" },
        .{ .name = prefix ++ "MAX_TOOL_ITERATIONS", .value = "5" },
    } };

    var report = try settings.loader.loadFromBytes(testing.allocator, cfg, env.lookup());
    defer report.deinit();

    var cache = settings.Cache.init();
    try testing.expectEqual(@as(u64, 0), cache.generation);

    cache.install(report.value());
    try testing.expectEqual(@as(u64, 1), cache.generation);
    try testing.expectEqual(settings.LogLevel.debug, cache.get().log_level);
    try testing.expectEqual(@as(u32, 5), cache.get().max_tool_iterations);
}

test "apply_change: valid patch installs; invalid patch is rejected and cache is preserved" {
    var empty_env = MapLookup{ .entries = &.{} };
    var report = try settings.loader.loadFromBytes(
        testing.allocator,
        "{}",
        empty_env.lookup(),
    );
    defer report.deinit();

    var cache = settings.Cache.init();
    cache.install(report.value());
    const before = cache.get();
    const gen_before = cache.generation;

    try settings.apply_change.apply(testing.allocator, &cache, .{ .mode = .bench });
    try testing.expectEqual(settings.Mode.bench, cache.get().mode);
    try testing.expectEqual(gen_before + 1, cache.generation);

    try testing.expectError(
        error.InvalidSettings,
        settings.apply_change.apply(testing.allocator, &cache, .{ .max_tool_iterations = 0 }),
    );
    // Mode still .bench from the previous successful patch.
    try testing.expectEqual(settings.Mode.bench, cache.get().mode);
    // Generation did not advance on the failed apply.
    try testing.expectEqual(gen_before + 1, cache.generation);

    _ = before;
}
