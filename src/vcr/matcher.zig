//! Matches a live `Request` to a recorded `Interaction`.
//!
//! The default `Policy` is strict — method, URL, and (if either side
//! carries one) body must be byte-equal. Cassettes trade flexibility for
//! signal: when a match fails, we want the diff to point at the actual
//! change, not to have been papered over by a loose matcher.

const std = @import("std");
const cassette = @import("cassette.zig");

pub const Policy = struct {
    method: bool = true,
    url: bool = true,
    body: bool = true,
};

pub fn matches(
    policy: Policy,
    live: cassette.Request,
    recorded: cassette.Request,
) bool {
    if (policy.method and !std.mem.eql(u8, live.method, recorded.method)) return false;
    if (policy.url and !std.mem.eql(u8, live.url, recorded.url)) return false;
    if (policy.body) {
        const a = live.body;
        const b = recorded.body;
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        if (!std.mem.eql(u8, a.?, b.?)) return false;
    }
    return true;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn req(method: []const u8, url: []const u8, body: ?[]const u8) cassette.Request {
    return .{ .method = method, .url = url, .body = body };
}

test "matches: identical requests match under default policy" {
    const a = req("POST", "https://x/y", "{}");
    const b = req("POST", "https://x/y", "{}");
    try testing.expect(matches(.{}, a, b));
}

test "matches: method mismatch fails" {
    try testing.expect(!matches(.{}, req("GET", "/x", null), req("POST", "/x", null)));
}

test "matches: url mismatch fails" {
    try testing.expect(!matches(.{}, req("GET", "/x", null), req("GET", "/y", null)));
}

test "matches: body mismatch fails under strict policy" {
    try testing.expect(!matches(.{}, req("POST", "/x", "{\"a\":1}"), req("POST", "/x", "{\"a\":2}")));
}

test "matches: body mismatch ignored when body: false" {
    try testing.expect(matches(.{ .body = false }, req("POST", "/x", "{\"a\":1}"), req("POST", "/x", "{\"a\":2}")));
}

test "matches: null bodies match only each other" {
    try testing.expect(matches(.{}, req("POST", "/x", null), req("POST", "/x", null)));
    try testing.expect(!matches(.{}, req("POST", "/x", null), req("POST", "/x", "{}")));
    try testing.expect(!matches(.{}, req("POST", "/x", "{}"), req("POST", "/x", null)));
}
