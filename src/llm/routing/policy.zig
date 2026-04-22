//! Routing policy.
//!
//! A `Policy` is a static table that maps an incoming request (by its
//! `ModelRef.provider` slug) to a preference-ordered list of provider
//! slugs the router may try. The router is the one that does the
//! actual dispatch; this file only decides "for this request, try
//! these names in this order."
//!
//! Policies are intentionally static — no evaluation, no env-var hooks.
//! Config lands in the settings subsystem and is converted into a
//! Policy at load time.

const std = @import("std");

pub const Rule = struct {
    /// Byte-equal to `ModelRef.provider`.
    request_provider: []const u8,
    /// Tried left-to-right. Must have at least one entry.
    fallback_chain: []const []const u8,
};

pub const Policy = struct {
    rules: []const Rule,
    /// Used when no rule matches the request provider.
    default_chain: []const []const u8 = &.{},

    pub fn chainFor(self: Policy, request_provider: []const u8) []const []const u8 {
        for (self.rules) |r| {
            if (std.mem.eql(u8, r.request_provider, request_provider)) return r.fallback_chain;
        }
        return self.default_chain;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "chainFor: matched rule returns its fallback chain" {
    const anthropic_chain = [_][]const u8{ "anthropic", "bedrock" };
    const policy = Policy{
        .rules = &.{
            .{ .request_provider = "anthropic", .fallback_chain = &anthropic_chain },
        },
    };
    const got = policy.chainFor("anthropic");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("anthropic", got[0]);
    try testing.expectEqualStrings("bedrock", got[1]);
}

test "chainFor: unmatched request returns default_chain" {
    const default = [_][]const u8{"mock"};
    const policy = Policy{ .rules = &.{}, .default_chain = &default };
    const got = policy.chainFor("unknown");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("mock", got[0]);
}

test "chainFor: unmatched request with no default is empty" {
    const policy = Policy{ .rules = &.{} };
    const got = policy.chainFor("unknown");
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "chainFor: first matching rule wins" {
    const first = [_][]const u8{"first"};
    const second = [_][]const u8{"second"};
    const policy = Policy{
        .rules = &.{
            .{ .request_provider = "x", .fallback_chain = &first },
            .{ .request_provider = "x", .fallback_chain = &second },
        },
    };
    const got = policy.chainFor("x");
    try testing.expectEqualStrings("first", got[0]);
}
