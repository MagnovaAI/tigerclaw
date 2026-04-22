//! Network-egress check.
//!
//! Decides whether a given `host`/`port` pair is permitted under
//! the session's `NetPolicy`. Pure function, no DNS, no sockets,
//! no allocation.
//!
//! Host matching:
//!   * An allowlist entry without a leading dot is matched
//!     case-insensitively against the full host.
//!   * An allowlist entry starting with `.` is a domain suffix:
//!     `.example.com` matches `api.example.com` and
//!     `example.com` but not `badexample.com`.
//!   * The single entry `"."` matches every host — useful as
//!     "network fully open" in `loose_run` mode.
//!
//! Port matching: an empty `port_allowlist` means "any port", so
//! the common case (HTTPS to allowlisted hosts) doesn't need the
//! caller to enumerate 443 explicitly.

const std = @import("std");
const policy_mod = @import("policy.zig");

pub const Decision = enum { allow, deny };

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

pub fn hostMatches(host: []const u8, entry: []const u8) bool {
    if (entry.len == 0) return false;
    // "." — sentinel for "match anything". The canonical all-hosts
    // entry; documented above.
    if (entry.len == 1 and entry[0] == '.') return true;

    if (entry[0] == '.') {
        // Domain suffix. Strip the leading dot for the apex match.
        const suffix = entry[1..];
        if (eqlIgnoreCase(host, suffix)) return true;
        // Otherwise require the dotted boundary — `.example.com`
        // must match `api.example.com`, not `badexample.com`.
        return endsWithIgnoreCase(host, entry);
    }

    return eqlIgnoreCase(host, entry);
}

pub fn check(net_policy: policy_mod.NetPolicy, host: []const u8, port: u16) Decision {
    // Port first: cheapest check, and a wrong port is the most
    // common misconfig.
    if (net_policy.port_allowlist.len != 0) {
        var port_ok = false;
        for (net_policy.port_allowlist) |allowed| {
            if (allowed == port) {
                port_ok = true;
                break;
            }
        }
        if (!port_ok) return .deny;
    }

    for (net_policy.host_allowlist) |entry| {
        if (hostMatches(host, entry)) return .allow;
    }
    return .deny;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "hostMatches: exact, case-insensitive" {
    try testing.expect(hostMatches("api.example.com", "API.example.COM"));
    try testing.expect(!hostMatches("api.example.com", "api.example.net"));
}

test "hostMatches: suffix semantics require a dot boundary" {
    try testing.expect(hostMatches("api.example.com", ".example.com"));
    try testing.expect(hostMatches("example.com", ".example.com"));
    try testing.expect(!hostMatches("badexample.com", ".example.com"));
}

test "hostMatches: single dot is wildcard" {
    try testing.expect(hostMatches("anything.example.com", "."));
    try testing.expect(hostMatches("", "."));
}

test "check: strict default denies everything" {
    try testing.expectEqual(Decision.deny, check(.{}, "example.com", 443));
}

test "check: allowlisted host, any port" {
    const p = policy_mod.NetPolicy{ .host_allowlist = &.{"api.example.com"} };
    try testing.expectEqual(Decision.allow, check(p, "api.example.com", 443));
    try testing.expectEqual(Decision.allow, check(p, "api.example.com", 8080));
    try testing.expectEqual(Decision.deny, check(p, "other.example.com", 443));
}

test "check: port allowlist filters by port" {
    const p = policy_mod.NetPolicy{
        .host_allowlist = &.{"api.example.com"},
        .port_allowlist = &.{ 443, 8443 },
    };
    try testing.expectEqual(Decision.allow, check(p, "api.example.com", 443));
    try testing.expectEqual(Decision.allow, check(p, "api.example.com", 8443));
    try testing.expectEqual(Decision.deny, check(p, "api.example.com", 80));
}

test "check: suffix match reaches subdomains" {
    const p = policy_mod.NetPolicy{ .host_allowlist = &.{".example.com"} };
    try testing.expectEqual(Decision.allow, check(p, "api.example.com", 443));
    try testing.expectEqual(Decision.allow, check(p, "example.com", 443));
    try testing.expectEqual(Decision.deny, check(p, "example.net", 443));
}
