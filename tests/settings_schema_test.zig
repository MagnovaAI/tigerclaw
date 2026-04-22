//! Integration test: a complete JSONC-shaped config parses through the
//! schema, validates, and resolves to a predictable path.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const settings = tigerclaw.settings;

const testing = std.testing;

test "end-to-end: JSON config parses and validates" {
    const config_bytes =
        \\{
        \\  "log_level": "warn",
        \\  "mode": "bench",
        \\  "max_tool_iterations": 200,
        \\  "max_history_messages": 50,
        \\  "monthly_budget_cents": 500
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        settings.Settings,
        testing.allocator,
        config_bytes,
        .{},
    );
    defer parsed.deinit();

    var issues: std.array_list.Aligned(settings.validation.Issue, null) = .empty;
    defer issues.deinit(testing.allocator);
    try issues.ensureTotalCapacity(testing.allocator, 4);

    try settings.validation.validate(testing.allocator, parsed.value, &issues);
    try testing.expectEqual(@as(usize, 0), issues.items.len);

    try testing.expectEqual(settings.LogLevel.warn, parsed.value.log_level);
    try testing.expectEqual(settings.Mode.bench, parsed.value.mode);
    try testing.expectEqual(@as(u32, 200), parsed.value.max_tool_iterations);
}

test "end-to-end: config with zero max_tool_iterations fails validation" {
    const config_bytes =
        \\{"log_level":"info","mode":"run","max_tool_iterations":0,"max_history_messages":10,"monthly_budget_cents":0}
    ;

    const parsed = try std.json.parseFromSlice(
        settings.Settings,
        testing.allocator,
        config_bytes,
        .{},
    );
    defer parsed.deinit();

    var issues: std.array_list.Aligned(settings.validation.Issue, null) = .empty;
    defer issues.deinit(testing.allocator);
    try issues.ensureTotalCapacity(testing.allocator, 4);

    try testing.expectError(
        error.InvalidSettings,
        settings.validation.validate(testing.allocator, parsed.value, &issues),
    );
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqualStrings("max_tool_iterations", issues.items[0].field);
}

test "end-to-end: path resolution follows flag > env > xdg > home precedence" {
    const r1 = try settings.managed_path.resolve(testing.allocator, .{
        .flag = "/a.jsonc",
        .env_config = "/b.jsonc",
        .env_xdg = "/xdg",
        .env_home = "/home",
    });
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("/a.jsonc", r1.path);

    const r2 = try settings.managed_path.resolve(testing.allocator, .{
        .env_xdg = "/xdg",
        .env_home = "/home",
    });
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("/xdg/tigerclaw/config.jsonc", r2.path);
}
