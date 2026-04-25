//! Typed channel identifiers.
//!
//! Canonical form: `<kind>:<subject>[:<sub>...]`
//!
//! Examples:
//!   chan-cli:local
//!   chan-discord:DM:123456789
//!   chan-telegram:chat:999
//!   chan-collab-stdio:subprocess-1
//!   chan-file-watch:/Users/omkarbhad/Documents
//!   chan-audio-in:default-mic
//!
//! Reply routing: envelopes reference their origin_channel_id; outbound
//! replies on reactive turns pin to the same ChannelId. That's the
//! invariant in turn_flow.reply_routing.

const std = @import("std");
const errors = @import("errors.zig");

const PlugError = errors.PlugError;

/// Known channel kinds. Append-only. Values here mirror the plug IDs
/// under extensions/channel-* and extensions/chan-collab-*.
pub const ChannelKind = enum {
    cli,
    discord,
    telegram,
    slack,
    imsg,
    whatsapp,
    signal,
    matrix,
    email,
    http_webhook,
    file_watch,
    audio_in,
    audio_out,
    vision_in,
    serial_in,
    collab_inprocess,
    collab_stdio,
    collab_http_a2a,
    collab_mcp,
    test_fake,
    unknown,

    pub fn prefix(self: ChannelKind) []const u8 {
        return switch (self) {
            .cli => "chan-cli",
            .discord => "chan-discord",
            .telegram => "chan-telegram",
            .slack => "chan-slack",
            .imsg => "chan-imsg",
            .whatsapp => "chan-whatsapp",
            .signal => "chan-signal",
            .matrix => "chan-matrix",
            .email => "chan-email",
            .http_webhook => "chan-http-webhook",
            .file_watch => "chan-file-watch",
            .audio_in => "chan-audio-in",
            .audio_out => "chan-audio-out",
            .vision_in => "chan-vision-in",
            .serial_in => "chan-serial-in",
            .collab_inprocess => "chan-collab-inprocess",
            .collab_stdio => "chan-collab-stdio",
            .collab_http_a2a => "chan-collab-http-a2a",
            .collab_mcp => "chan-collab-mcp",
            .test_fake => "chan-test-fake",
            .unknown => "chan-unknown",
        };
    }

    pub fn fromPrefix(p: []const u8) ?ChannelKind {
        const pairs = .{
            .{ "chan-cli", ChannelKind.cli },
            .{ "chan-discord", ChannelKind.discord },
            .{ "chan-telegram", ChannelKind.telegram },
            .{ "chan-slack", ChannelKind.slack },
            .{ "chan-imsg", ChannelKind.imsg },
            .{ "chan-whatsapp", ChannelKind.whatsapp },
            .{ "chan-signal", ChannelKind.signal },
            .{ "chan-matrix", ChannelKind.matrix },
            .{ "chan-email", ChannelKind.email },
            .{ "chan-http-webhook", ChannelKind.http_webhook },
            .{ "chan-file-watch", ChannelKind.file_watch },
            .{ "chan-audio-in", ChannelKind.audio_in },
            .{ "chan-audio-out", ChannelKind.audio_out },
            .{ "chan-vision-in", ChannelKind.vision_in },
            .{ "chan-serial-in", ChannelKind.serial_in },
            .{ "chan-collab-inprocess", ChannelKind.collab_inprocess },
            .{ "chan-collab-stdio", ChannelKind.collab_stdio },
            .{ "chan-collab-http-a2a", ChannelKind.collab_http_a2a },
            .{ "chan-collab-mcp", ChannelKind.collab_mcp },
            .{ "chan-test-fake", ChannelKind.test_fake },
            .{ "chan-unknown", ChannelKind.unknown },
        };
        inline for (pairs) |pair| {
            if (std.mem.eql(u8, p, pair[0])) return pair[1];
        }
        return null;
    }
};

pub const max_raw_len: usize = 512;

pub const ChannelId = struct {
    raw: []const u8,

    /// Parse a canonical channel id. The kind prefix must be a known
    /// ChannelKind; the subject (after the first colon) must be
    /// non-empty. Subject may contain additional colons (e.g.
    /// "chan-discord:DM:123").
    pub fn parse(s: []const u8) PlugError!ChannelId {
        if (s.len == 0) return error.BadInput;
        if (s.len > max_raw_len) return error.BadInput;

        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadInput;
        const prefix_str = s[0..colon];
        if (prefix_str.len == 0) return error.BadInput;

        const rest = s[colon + 1 ..];
        if (rest.len == 0) return error.BadInput;

        if (ChannelKind.fromPrefix(prefix_str) == null) return error.BadInput;

        return .{ .raw = s };
    }

    pub fn kind(self: ChannelId) ChannelKind {
        const colon = std.mem.indexOfScalar(u8, self.raw, ':') orelse return .unknown;
        return ChannelKind.fromPrefix(self.raw[0..colon]) orelse .unknown;
    }

    pub fn subject(self: ChannelId) []const u8 {
        const colon = std.mem.indexOfScalar(u8, self.raw, ':') orelse return self.raw;
        return self.raw[colon + 1 ..];
    }

    pub fn eql(a: ChannelId, b: ChannelId) bool {
        return std.mem.eql(u8, a.raw, b.raw);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: accepts canonical channel forms" {
    const cases = [_]struct { raw: []const u8, want_kind: ChannelKind }{
        .{ .raw = "chan-cli:local", .want_kind = .cli },
        .{ .raw = "chan-discord:DM:123456789", .want_kind = .discord },
        .{ .raw = "chan-telegram:chat:999", .want_kind = .telegram },
        .{ .raw = "chan-collab-stdio:sub-1", .want_kind = .collab_stdio },
        .{ .raw = "chan-file-watch:/Users/omkar/notes", .want_kind = .file_watch },
        .{ .raw = "chan-audio-in:default", .want_kind = .audio_in },
    };
    for (cases) |c| {
        const id = try ChannelId.parse(c.raw);
        try testing.expectEqual(c.want_kind, id.kind());
    }
}

test "parse: rejects empty" {
    try testing.expectError(error.BadInput, ChannelId.parse(""));
}

test "parse: rejects no colon" {
    try testing.expectError(error.BadInput, ChannelId.parse("chan-cli"));
}

test "parse: rejects empty kind" {
    try testing.expectError(error.BadInput, ChannelId.parse(":local"));
}

test "parse: rejects empty subject" {
    try testing.expectError(error.BadInput, ChannelId.parse("chan-cli:"));
}

test "parse: rejects unknown kind" {
    try testing.expectError(error.BadInput, ChannelId.parse("chan-martian:landing-pad"));
}

test "parse: rejects oversize" {
    const too_long = "chan-cli:" ++ "x" ** 600;
    try testing.expectError(error.BadInput, ChannelId.parse(too_long));
}

test "subject: returns everything after first colon" {
    const id = try ChannelId.parse("chan-discord:DM:123");
    try testing.expectEqualStrings("DM:123", id.subject());
}

test "eql: byte-equal ids match" {
    const a = try ChannelId.parse("chan-cli:local");
    const b = try ChannelId.parse("chan-cli:local");
    try testing.expect(a.eql(b));
}
