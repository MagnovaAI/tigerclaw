//! Envelope — canonical cross-boundary message shape.
//!
//! Mirrors `spec/envelope.proto` v1 as a Zig struct. This module is
//! pure data types + a builder; wire encoding lives in
//! `envelope_codec.zig`, signing lives in `envelope_sig.zig`.
//!
//! Field numbers referenced in comments match the .proto file: that
//! mapping is what the codec relies on to produce proto3-deterministic
//! canonical bytes. Never reorder fields without bumping the schema
//! version in the .proto AND this module.
//!
//! In-process plug-to-plug calls use this struct directly — no codec
//! on the hot path. Protobuf encoding only happens when bytes cross a
//! process boundary.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.envelope
//!       spec/envelope.proto

const std = @import("std");
const errors = @import("errors.zig");

const PlugError = errors.PlugError;

/// Current envelope schema version. Decoders reject any other value.
pub const EnvelopeV: u32 = 1;

/// Kinds of envelopes. Integer values match the .proto Verb enum
/// exactly; changing one here without updating the .proto breaks the
/// wire.
pub const Verb = enum(u32) {
    unspecified = 0,
    user_msg = 1,
    tool_call = 2,
    tool_result = 3,
    reply = 4,
    retract = 5,
    hello = 6,
    hello_ack = 7,
    refuse = 8,
    heartbeat = 9,

    /// Human-readable name matching the proto textual form.
    pub fn name(self: Verb) []const u8 {
        return switch (self) {
            .unspecified => "VERB_UNSPECIFIED",
            .user_msg => "USER_MSG",
            .tool_call => "TOOL_CALL",
            .tool_result => "TOOL_RESULT",
            .reply => "REPLY",
            .retract => "RETRACT",
            .hello => "HELLO",
            .hello_ack => "HELLO_ACK",
            .refuse => "REFUSE",
            .heartbeat => "HEARTBEAT",
        };
    }
};

/// Attachment carried inline in an envelope. Large blobs belong in the
/// content-addressed blob store and are referenced via body MIME
/// "application/vnd.tigerclaw.blobref" rather than serialized here.
pub const Attachment = struct {
    /// .proto field 1
    name: []const u8,
    /// .proto field 2
    mime: []const u8,
    /// .proto field 3
    data: []const u8,
};

/// Per-turn cross-boundary message. Field numbers in comments match
/// spec/envelope.proto.
pub const Envelope = struct {
    /// .proto field 1 — schema version. Must be EnvelopeV on decode.
    envelope_v: u32 = EnvelopeV,

    /// .proto field 2 — message kind.
    verb: Verb,

    /// .proto field 3 — conversation identifier.
    conversation_id: []const u8,

    /// .proto field 4 — id of the envelope being replied to, if any.
    in_reply_to: ?[]const u8 = null,

    /// .proto field 5 — origin channel id (canonical string form).
    origin_channel_id: []const u8,

    /// .proto field 6 — peer id of the sender.
    sender_id: []const u8,

    /// .proto field 7 — ed25519 signature over canonical bytes.
    /// EXCLUDED from canonical encoding.
    sender_sig: ?[]const u8 = null,

    /// .proto field 8 — send timestamp, ms since Unix epoch.
    sent_at_ms: i64,

    /// .proto field 9 — optional replay-protection nonce.
    nonce: ?[]const u8 = null,

    /// .proto field 10 — MIME type of body.
    body_mime: []const u8 = "application/json",

    /// .proto field 11 — opaque payload. Interpretation depends on verb.
    body: []const u8,

    /// .proto field 12 — optional budget ceilings.
    max_tokens: ?u32 = null,
    /// .proto field 13
    max_wall_ms: ?u32 = null,
    /// .proto field 14
    max_cost_usd_micros: ?u32 = null,

    /// .proto field 15 — inline attachments.
    attachments: []const Attachment = &.{},

    /// .proto field 16 — optional thread/topic key within the
    /// conversation. Preserved end-to-end so threaded channels
    /// (Telegram topics, Slack thread_ts, Discord threads) route
    /// replies back onto the originating thread. Null for
    /// single-threaded channels.
    thread_key: ?[]const u8 = null,

    /// Builder with validation. Required fields must be set before
    /// calling `build()`. Returns PlugError.BadInput if any required
    /// field is missing or empty.
    pub const Builder = struct {
        env: Envelope = .{
            .verb = .unspecified,
            .conversation_id = "",
            .origin_channel_id = "",
            .sender_id = "",
            .sent_at_ms = 0,
            .body = "",
        },

        pub fn init() Builder {
            return .{};
        }

        pub fn verb(self: *Builder, v: Verb) *Builder {
            self.env.verb = v;
            return self;
        }

        pub fn conversationId(self: *Builder, id: []const u8) *Builder {
            self.env.conversation_id = id;
            return self;
        }

        pub fn inReplyTo(self: *Builder, id: []const u8) *Builder {
            self.env.in_reply_to = id;
            return self;
        }

        pub fn originChannelId(self: *Builder, id: []const u8) *Builder {
            self.env.origin_channel_id = id;
            return self;
        }

        pub fn senderId(self: *Builder, id: []const u8) *Builder {
            self.env.sender_id = id;
            return self;
        }

        pub fn sentAtMs(self: *Builder, ms: i64) *Builder {
            self.env.sent_at_ms = ms;
            return self;
        }

        pub fn nonce(self: *Builder, n: []const u8) *Builder {
            self.env.nonce = n;
            return self;
        }

        pub fn bodyMime(self: *Builder, mime: []const u8) *Builder {
            self.env.body_mime = mime;
            return self;
        }

        pub fn body(self: *Builder, b: []const u8) *Builder {
            self.env.body = b;
            return self;
        }

        pub fn maxTokens(self: *Builder, t: u32) *Builder {
            self.env.max_tokens = t;
            return self;
        }

        pub fn maxWallMs(self: *Builder, ms: u32) *Builder {
            self.env.max_wall_ms = ms;
            return self;
        }

        pub fn maxCostUsdMicros(self: *Builder, c: u32) *Builder {
            self.env.max_cost_usd_micros = c;
            return self;
        }

        pub fn attachments(self: *Builder, a: []const Attachment) *Builder {
            self.env.attachments = a;
            return self;
        }

        pub fn threadKey(self: *Builder, k: []const u8) *Builder {
            self.env.thread_key = k;
            return self;
        }

        /// Validate and return the envelope. Required fields: verb
        /// (non-unspecified), conversation_id, origin_channel_id,
        /// sender_id, sent_at_ms (>= 0), body_mime, body.
        pub fn build(self: Builder) PlugError!Envelope {
            if (self.env.verb == .unspecified) return error.BadInput;
            if (self.env.conversation_id.len == 0) return error.BadInput;
            if (self.env.origin_channel_id.len == 0) return error.BadInput;
            if (self.env.sender_id.len == 0) return error.BadInput;
            if (self.env.sent_at_ms < 0) return error.BadInput;
            if (self.env.body_mime.len == 0) return error.BadInput;
            // body may be empty (e.g. heartbeat), so no length check.
            return self.env;
        }
    };

    /// Construct a reply envelope that inherits conversation_id and
    /// origin_channel_id from `self`. Caller supplies sender_id + body
    /// + timestamp; this helper just does the plumbing.
    pub fn newReply(
        self: *const Envelope,
        sender_id_val: []const u8,
        sent_at_ms_val: i64,
        body_val: []const u8,
        in_reply_to_id: []const u8,
    ) PlugError!Envelope {
        var b = Builder.init();
        _ = b.verb(.reply);
        _ = b.conversationId(self.conversation_id);
        _ = b.originChannelId(self.origin_channel_id);
        _ = b.senderId(sender_id_val);
        _ = b.sentAtMs(sent_at_ms_val);
        _ = b.inReplyTo(in_reply_to_id);
        _ = b.body(body_val);
        // Pin replies to the originating thread so threaded channels
        // route the response back onto the correct topic.
        if (self.thread_key) |k| _ = b.threadKey(k);
        return b.build();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Verb.name: returns proto-text form" {
    try testing.expectEqualStrings("USER_MSG", Verb.user_msg.name());
    try testing.expectEqualStrings("HELLO_ACK", Verb.hello_ack.name());
    try testing.expectEqualStrings("VERB_UNSPECIFIED", Verb.unspecified.name());
}

test "Builder: happy path constructs valid envelope" {
    var b = Envelope.Builder.init();
    const env = try b
        .verb(.user_msg)
        .conversationId("conv-01")
        .originChannelId("chan-cli:local")
        .senderId("user:omkar")
        .sentAtMs(1745000000000)
        .body("{\"text\":\"hi\"}")
        .build();

    try testing.expectEqual(Verb.user_msg, env.verb);
    try testing.expectEqualStrings("conv-01", env.conversation_id);
    try testing.expectEqual(@as(u32, 1), env.envelope_v);
    try testing.expectEqualStrings("application/json", env.body_mime);
}

test "Builder: rejects missing verb" {
    var b = Envelope.Builder.init();
    const err = b
        .conversationId("c")
        .originChannelId("o")
        .senderId("s")
        .sentAtMs(1)
        .body("b")
        .build();
    try testing.expectError(error.BadInput, err);
}

test "Builder: rejects empty conversation_id" {
    var b = Envelope.Builder.init();
    const err = b
        .verb(.reply)
        .originChannelId("o")
        .senderId("s")
        .sentAtMs(1)
        .body("b")
        .build();
    try testing.expectError(error.BadInput, err);
}

test "Builder: rejects negative sent_at_ms" {
    var b = Envelope.Builder.init();
    const err = b
        .verb(.heartbeat)
        .conversationId("c")
        .originChannelId("o")
        .senderId("s")
        .sentAtMs(-1)
        .body("")
        .build();
    try testing.expectError(error.BadInput, err);
}

test "Builder: accepts empty body (heartbeat)" {
    var b = Envelope.Builder.init();
    const env = try b
        .verb(.heartbeat)
        .conversationId("hb-01")
        .originChannelId("chan-cli:local")
        .senderId("agent:tiger")
        .sentAtMs(1745000030000)
        .bodyMime("application/octet-stream")
        .body("")
        .build();
    try testing.expectEqual(Verb.heartbeat, env.verb);
    try testing.expectEqual(@as(usize, 0), env.body.len);
}

test "newReply: inherits conversation_id and origin_channel_id" {
    var b = Envelope.Builder.init();
    const inbound = try b
        .verb(.user_msg)
        .conversationId("conv-42")
        .originChannelId("chan-discord:DM:123")
        .senderId("discord_user:omkar")
        .sentAtMs(1745000000000)
        .body("{\"text\":\"hi\"}")
        .build();

    const reply = try inbound.newReply("agent:tiger", 1745000001000, "{\"text\":\"hello\"}", "env-1");

    try testing.expectEqual(Verb.reply, reply.verb);
    try testing.expectEqualStrings("conv-42", reply.conversation_id);
    try testing.expectEqualStrings("chan-discord:DM:123", reply.origin_channel_id);
    try testing.expectEqualStrings("agent:tiger", reply.sender_id);
    try testing.expect(reply.in_reply_to != null);
    try testing.expectEqualStrings("env-1", reply.in_reply_to.?);
}

test "newReply: pins thread_key to inbound" {
    var b = Envelope.Builder.init();
    const inbound = try b
        .verb(.user_msg)
        .conversationId("conv-42")
        .originChannelId("chan-telegram:group:777")
        .senderId("user:omkar")
        .sentAtMs(1745000000000)
        .threadKey("topic-3")
        .body("{\"text\":\"hi\"}")
        .build();

    const reply = try inbound.newReply("agent:tiger", 1745000001000, "{\"text\":\"hello\"}", "env-1");
    try testing.expect(reply.thread_key != null);
    try testing.expectEqualStrings("topic-3", reply.thread_key.?);
}

test "newReply: thread_key stays null when inbound has none" {
    var b = Envelope.Builder.init();
    const inbound = try b
        .verb(.user_msg)
        .conversationId("conv-42")
        .originChannelId("chan-cli:local")
        .senderId("user:omkar")
        .sentAtMs(1745000000000)
        .body("{\"text\":\"hi\"}")
        .build();

    const reply = try inbound.newReply("agent:tiger", 1745000001000, "{\"text\":\"hello\"}", "env-1");
    try testing.expectEqual(@as(?[]const u8, null), reply.thread_key);
}

test "EnvelopeV: locked at 1" {
    // This is a wire-format contract. Bumping the constant requires a
    // new .proto file (envelope_v=2) and a migration plan.
    try testing.expectEqual(@as(u32, 1), EnvelopeV);
}

test "Verb integer values match .proto" {
    // Wire-format contract: these integer values appear on the wire and
    // must never change without a version bump.
    try testing.expectEqual(@as(u32, 0), @intFromEnum(Verb.unspecified));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Verb.user_msg));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(Verb.tool_call));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(Verb.tool_result));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(Verb.reply));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(Verb.retract));
    try testing.expectEqual(@as(u32, 6), @intFromEnum(Verb.hello));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(Verb.hello_ack));
    try testing.expectEqual(@as(u32, 8), @intFromEnum(Verb.refuse));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(Verb.heartbeat));
}
