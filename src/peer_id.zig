//! Typed peer identifiers.
//!
//! Raw strings like "user:omkar" crossing plug boundaries are a bug
//! magnet. PeerId wraps the canonical form with parse + kind lookup +
//! validation. The raw bytes stay borrowed — no allocation — so this
//! is a zero-cost typed wrapper.
//!
//! Canonical form: `<kind>:<identifier>[:<sub>]`
//!
//! Examples:
//!   user:omkar
//!   agent:reviewer-01
//!   discord_user:112233445566
//!   telegram_user:999888777
//!   imsg_user:+15551234567
//!   sensor:camera-kitchen
//!
//! Parse validates: non-empty kind, non-empty identifier, kind is a
//! known PeerKind, total length <= 256. Everything else is BadInput.
//!
//! Lifetime: PeerId borrows from its source bytes. Callers must keep
//! the source alive or dupe into their own allocator.

const std = @import("std");
const errors = @import("errors.zig");

const PlugError = errors.PlugError;

/// Known peer kinds. New kinds append at the end; integer tags are
/// not a wire contract here (raw string is), but stability is useful
/// for pattern matching.
pub const PeerKind = enum {
    user,
    agent,
    discord_user,
    slack_user,
    telegram_user,
    imsg_user,
    whatsapp_user,
    sensor,
    tool,
    service,
    unknown,

    pub fn prefix(self: PeerKind) []const u8 {
        return switch (self) {
            .user => "user",
            .agent => "agent",
            .discord_user => "discord_user",
            .slack_user => "slack_user",
            .telegram_user => "telegram_user",
            .imsg_user => "imsg_user",
            .whatsapp_user => "whatsapp_user",
            .sensor => "sensor",
            .tool => "tool",
            .service => "service",
            .unknown => "unknown",
        };
    }

    pub fn fromPrefix(p: []const u8) ?PeerKind {
        const pairs = .{
            .{ "user", PeerKind.user },
            .{ "agent", PeerKind.agent },
            .{ "discord_user", PeerKind.discord_user },
            .{ "slack_user", PeerKind.slack_user },
            .{ "telegram_user", PeerKind.telegram_user },
            .{ "imsg_user", PeerKind.imsg_user },
            .{ "whatsapp_user", PeerKind.whatsapp_user },
            .{ "sensor", PeerKind.sensor },
            .{ "tool", PeerKind.tool },
            .{ "service", PeerKind.service },
            .{ "unknown", PeerKind.unknown },
        };
        inline for (pairs) |pair| {
            if (std.mem.eql(u8, p, pair[0])) return pair[1];
        }
        return null;
    }
};

pub const max_raw_len: usize = 256;

pub const PeerId = struct {
    raw: []const u8, // canonical "kind:identifier[:sub]"; borrowed

    /// Parse a canonical peer id. Returns BadInput on: empty string,
    /// missing colon, empty kind, empty identifier, unknown kind,
    /// length > max_raw_len.
    pub fn parse(s: []const u8) PlugError!PeerId {
        if (s.len == 0) return error.BadInput;
        if (s.len > max_raw_len) return error.BadInput;

        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadInput;
        const kind_str = s[0..colon];
        if (kind_str.len == 0) return error.BadInput;

        // Everything after the first colon is the identifier (may
        // contain further colons for "discord_user:guild:user" etc).
        const rest = s[colon + 1 ..];
        if (rest.len == 0) return error.BadInput;

        if (PeerKind.fromPrefix(kind_str) == null) return error.BadInput;

        return .{ .raw = s };
    }

    /// Returns the declared peer kind. Unknown kind would have failed
    /// parse(), so this can't return .unknown unless the caller
    /// constructed a PeerId without parse (which they shouldn't).
    pub fn kind(self: PeerId) PeerKind {
        const colon = std.mem.indexOfScalar(u8, self.raw, ':') orelse return .unknown;
        return PeerKind.fromPrefix(self.raw[0..colon]) orelse .unknown;
    }

    /// Returns the identifier portion (everything after the first colon).
    pub fn identifier(self: PeerId) []const u8 {
        const colon = std.mem.indexOfScalar(u8, self.raw, ':') orelse return self.raw;
        return self.raw[colon + 1 ..];
    }

    /// Byte-equality (the raw forms must match exactly).
    pub fn eql(a: PeerId, b: PeerId) bool {
        return std.mem.eql(u8, a.raw, b.raw);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: accepts canonical forms" {
    const cases = [_]struct { raw: []const u8, want_kind: PeerKind }{
        .{ .raw = "user:omkar", .want_kind = .user },
        .{ .raw = "agent:reviewer-01", .want_kind = .agent },
        .{ .raw = "discord_user:112233445566", .want_kind = .discord_user },
        .{ .raw = "telegram_user:999", .want_kind = .telegram_user },
        .{ .raw = "imsg_user:+15551234567", .want_kind = .imsg_user },
        .{ .raw = "sensor:camera-kitchen", .want_kind = .sensor },
        .{ .raw = "tool:fs", .want_kind = .tool },
    };
    for (cases) |c| {
        const id = try PeerId.parse(c.raw);
        try testing.expectEqual(c.want_kind, id.kind());
        try testing.expectEqualStrings(c.raw, id.raw);
    }
}

test "parse: accepts nested identifier with sub-colons" {
    const id = try PeerId.parse("discord_user:guild-123:user-456");
    try testing.expectEqual(PeerKind.discord_user, id.kind());
    try testing.expectEqualStrings("guild-123:user-456", id.identifier());
}

test "parse: rejects empty" {
    try testing.expectError(error.BadInput, PeerId.parse(""));
}

test "parse: rejects no colon" {
    try testing.expectError(error.BadInput, PeerId.parse("omkar"));
}

test "parse: rejects empty kind" {
    try testing.expectError(error.BadInput, PeerId.parse(":omkar"));
}

test "parse: rejects empty identifier" {
    try testing.expectError(error.BadInput, PeerId.parse("user:"));
}

test "parse: rejects unknown kind" {
    try testing.expectError(error.BadInput, PeerId.parse("martian:zogg"));
}

test "parse: rejects oversize" {
    const too_long = "user:" ++ "x" ** 300;
    try testing.expectError(error.BadInput, PeerId.parse(too_long));
}

test "eql: byte-identical ids are equal" {
    const a = try PeerId.parse("user:omkar");
    const b = try PeerId.parse("user:omkar");
    try testing.expect(a.eql(b));
}

test "eql: different identifiers are not equal" {
    const a = try PeerId.parse("user:omkar");
    const b = try PeerId.parse("user:alice");
    try testing.expect(!a.eql(b));
}

test "raw access: lets callers stringify directly" {
    const id = try PeerId.parse("agent:tiger");
    try testing.expectEqualStrings("agent:tiger", id.raw);
}
