//! A fully-qualified reference to a provider model.
//!
//! `provider` is the canonical provider slug ("anthropic", "openai", ...).
//! `model` is the provider-specific id ("claude-opus-4-7", "gpt-4o").
//! Round-trippable via "<provider>/<model>".

const std = @import("std");

pub const ModelRef = struct {
    provider: []const u8,
    model: []const u8,

    pub fn toQualified(self: ModelRef, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.provider, self.model });
    }

    pub fn parse(qualified: []const u8) error{MissingSeparator}!ModelRef {
        const idx = std.mem.indexOfScalar(u8, qualified, '/') orelse
            return error.MissingSeparator;
        return .{
            .provider = qualified[0..idx],
            .model = qualified[idx + 1 ..],
        };
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "ModelRef: toQualified renders as provider/model" {
    const r = ModelRef{ .provider = "anthropic", .model = "claude-opus-4-7" };
    const s = try r.toQualified(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("anthropic/claude-opus-4-7", s);
}

test "ModelRef: parse roundtrips" {
    const r = try ModelRef.parse("openai/gpt-4o");
    try testing.expectEqualStrings("openai", r.provider);
    try testing.expectEqualStrings("gpt-4o", r.model);
}

test "ModelRef: parse without slash returns MissingSeparator" {
    try testing.expectError(error.MissingSeparator, ModelRef.parse("nope"));
}

test "ModelRef: model id containing a slash keeps the remainder" {
    const r = try ModelRef.parse("bedrock/anthropic.claude-3/v1");
    try testing.expectEqualStrings("bedrock", r.provider);
    try testing.expectEqualStrings("anthropic.claude-3/v1", r.model);
}

test "ModelRef: JSON roundtrip preserves both fields" {
    const r = ModelRef{ .provider = "openai", .model = "gpt-4o" };
    const s = try std.json.Stringify.valueAlloc(testing.allocator, r, .{});
    defer testing.allocator.free(s);

    const parsed = try std.json.parseFromSlice(ModelRef, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings(r.provider, parsed.value.provider);
    try testing.expectEqualStrings(r.model, parsed.value.model);
}
