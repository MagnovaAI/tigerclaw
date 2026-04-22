//! Secrets handling.
//!
//! Secrets live in a separate file (`.secret.jsonc` by convention) so the
//! main config can be safely checked in. This module exposes:
//!
//!   - `redact`: replaces secret values in a rendered config string with
//!     `"***"` so logs and trace fixtures don't leak them.
//!   - `isSecretKey`: canonical list of fields that carry secrets.
//!
//! Loading the secrets file belongs to the loader (forthcoming); this
//! module stays pure.

const std = @import("std");

pub const secret_key_suffixes = [_][]const u8{
    "_api_key",
    "_token",
    "_password",
    "_secret",
};

pub fn isSecretKey(key: []const u8) bool {
    for (secret_key_suffixes) |suffix| {
        if (std.mem.endsWith(u8, key, suffix)) return true;
    }
    return false;
}

pub const redaction = "***";

/// Parses `json_bytes` as a JSON object and returns a new allocation in
/// which every value whose key matches `isSecretKey` is replaced with
/// `"***"`. Non-object inputs are returned verbatim (after a copy).
pub fn redact(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_always },
    ) catch {
        return allocator.dupe(u8, json_bytes);
    };
    defer parsed.deinit();

    var root = parsed.value;
    switch (root) {
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (isSecretKey(entry.key_ptr.*)) {
                    entry.value_ptr.* = std.json.Value{ .string = redaction };
                }
            }
        },
        else => {},
    }

    return std.json.Stringify.valueAlloc(allocator, root, .{});
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "isSecretKey: matches canonical suffixes" {
    try testing.expect(isSecretKey("openai_api_key"));
    try testing.expect(isSecretKey("slack_token"));
    try testing.expect(isSecretKey("admin_password"));
    try testing.expect(isSecretKey("client_secret"));
}

test "isSecretKey: non-secrets pass through" {
    try testing.expect(!isSecretKey("log_level"));
    try testing.expect(!isSecretKey("mode"));
    try testing.expect(!isSecretKey("max_tool_iterations"));
}

test "redact: replaces secret values, preserves others" {
    const input = "{\"openai_api_key\":\"sk-live-abc\",\"log_level\":\"warn\"}";
    const out = try redact(testing.allocator, input);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "sk-live-abc") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"warn\"") != null);
}

test "redact: non-object input is copied verbatim" {
    const input = "[1,2,3]";
    const out = try redact(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[1,2,3]", out);
}

test "redact: malformed JSON returns a copy" {
    const input = "{not json";
    const out = try redact(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{not json", out);
}
