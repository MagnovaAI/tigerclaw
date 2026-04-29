//! Field-level validators for `Settings`.
//!
//! Validators run after JSON decoding but before the runtime installs the
//! settings. Each `ValidationError` names the field and the reason.

const std = @import("std");
const schema = @import("schema.zig");
const Settings = schema.Settings;

pub const Issue = struct {
    field: []const u8,
    reason: []const u8,
};

pub const ValidationError = error{
    InvalidSettings,
};

/// Writes each issue into `out`. Returns `error.InvalidSettings` if any
/// issues are emitted. `out` is caller-owned; it is appended to and not
/// cleared.
fn isValidHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://");
}

pub fn validate(
    allocator: std.mem.Allocator,
    s: Settings,
    out: *std.array_list.Aligned(Issue, null),
) ValidationError!void {
    _ = allocator;
    const start = out.items.len;

    if (s.max_tool_iterations == 0) {
        out.appendAssumeCapacity(.{
            .field = "max_tool_iterations",
            .reason = "must be greater than 0",
        });
    }
    if (s.max_history_messages == 0) {
        out.appendAssumeCapacity(.{
            .field = "max_history_messages",
            .reason = "must be greater than 0",
        });
    }
    if (s.monthly_budget_cents > 100 * 1_000_000) {
        out.appendAssumeCapacity(.{
            .field = "monthly_budget_cents",
            .reason = "exceeds sanity cap of $1,000,000",
        });
    }

    if (s.gateway.url.len > 0 and !isValidHttpUrl(s.gateway.url)) {
        out.appendAssumeCapacity(.{
            .field = "gateway.url",
            .reason = "must start with http:// or https://",
        });
    }
    if (s.gateway.url.len > 0 and s.gateway.token.len == 0) {
        out.appendAssumeCapacity(.{
            .field = "gateway.token",
            .reason = "required when gateway.url is set",
        });
    }
    if (s.agent.timeout_secs == 0) {
        out.appendAssumeCapacity(.{
            .field = "agent.timeout_secs",
            .reason = "must be greater than 0",
        });
    }
    if (s.agent.max_retries == 0) {
        out.appendAssumeCapacity(.{
            .field = "agent.max_retries",
            .reason = "must be greater than 0",
        });
    }

    if (out.items.len != start) return error.InvalidSettings;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn withCapacity(cap: usize) !std.array_list.Aligned(Issue, null) {
    var list: std.array_list.Aligned(Issue, null) = .empty;
    try list.ensureTotalCapacity(testing.allocator, cap);
    return list;
}

test "validate: defaults pass" {
    var issues = try withCapacity(4);
    defer issues.deinit(testing.allocator);

    try validate(testing.allocator, .{}, &issues);
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "validate: zero max_tool_iterations fails with field-targeted issue" {
    var issues = try withCapacity(4);
    defer issues.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .max_tool_iterations = 0 }, &issues),
    );
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqualStrings("max_tool_iterations", issues.items[0].field);
}

test "validate: zero max_history_messages fails" {
    var issues = try withCapacity(4);
    defer issues.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .max_history_messages = 0 }, &issues),
    );
    try testing.expectEqualStrings("max_history_messages", issues.items[0].field);
}

test "validate: budget beyond sanity cap fails" {
    var issues = try withCapacity(4);
    defer issues.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .monthly_budget_cents = 200 * 1_000_000 }, &issues),
    );
    try testing.expectEqualStrings("monthly_budget_cents", issues.items[0].field);
}

test "validate: gateway.url without scheme fails" {
    var issues = try withCapacity(8);
    defer issues.deinit(testing.allocator);
    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .gateway = .{ .url = "localhost:8765", .token = "t" } }, &issues),
    );
    try testing.expectEqualStrings("gateway.url", issues.items[0].field);
}

test "validate: gateway.url set but empty token fails" {
    var issues = try withCapacity(8);
    defer issues.deinit(testing.allocator);
    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .gateway = .{ .url = "http://localhost:8765", .token = "" } }, &issues),
    );
    try testing.expectEqualStrings("gateway.token", issues.items[0].field);
}

test "validate: valid gateway passes" {
    var issues = try withCapacity(8);
    defer issues.deinit(testing.allocator);
    try validate(testing.allocator, .{
        .gateway = .{ .url = "https://api.example.com", .token = "secret" },
    }, &issues);
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "validate: zero agent.timeout_secs fails" {
    var issues = try withCapacity(8);
    defer issues.deinit(testing.allocator);
    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{ .agent = .{ .timeout_secs = 0, .max_retries = 3 } }, &issues),
    );
    try testing.expectEqualStrings("agent.timeout_secs", issues.items[0].field);
}

test "validate: multiple bad fields reported in a single pass" {
    var issues = try withCapacity(4);
    defer issues.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidSettings,
        validate(testing.allocator, .{
            .max_tool_iterations = 0,
            .max_history_messages = 0,
        }, &issues),
    );
    try testing.expectEqual(@as(usize, 2), issues.items.len);
}
