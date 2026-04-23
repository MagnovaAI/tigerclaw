//! Envelope <-> protobuf bytes codec.
//!
//! Implements just enough of proto3 wire format to encode + decode
//! Envelope. Keeping the codec in-tree (rather than pulling nanopb or
//! another lib) buys:
//!   - zero external deps
//!   - deterministic canonical encoding on our terms
//!   - ~200 lines of Zig we can read and test line-by-line
//!
//! Proto3 wire-format cheat sheet:
//!   tag = (field_number << 3) | wire_type
//!   wire types used here:
//!     0 = varint        (uint32, int32, int64, uint64, bool, enum)
//!     2 = length-delim  (string, bytes, nested message)
//!   int64 sent_at_ms uses zig-zag? No — proto3 int64 is a plain
//!   varint over the two's-complement bits. We emit raw varint.
//!
//! Field numbers must match spec/envelope.proto exactly. Changing one
//! is a wire-breaking change.
//!
//! Encoding is DETERMINISTIC by construction:
//!   - fields emitted in field-number ascending order
//!   - unset optionals skipped (no tag written)
//!   - repeated attachments in declaration order
//!   - no extensions beyond v1 schema
//!
//! Canonical bytes for signing = output of `encode()` with
//! `include_sig = false`. See TIG-148 for the dedicated function.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.envelope
//!       spec/envelope.proto

const std = @import("std");
const envelope_mod = @import("envelope.zig");
const errors = @import("errors.zig");

const Envelope = envelope_mod.Envelope;
const Verb = envelope_mod.Verb;
const Attachment = envelope_mod.Attachment;
const PlugError = errors.PlugError;

// Field numbers. Wire contract: changes here require a .proto bump.
const F_ENVELOPE_V: u32 = 1;
const F_VERB: u32 = 2;
const F_CONVERSATION_ID: u32 = 3;
const F_IN_REPLY_TO: u32 = 4;
const F_ORIGIN_CHANNEL_ID: u32 = 5;
const F_SENDER_ID: u32 = 6;
const F_SENDER_SIG: u32 = 7;
const F_SENT_AT_MS: u32 = 8;
const F_NONCE: u32 = 9;
const F_BODY_MIME: u32 = 10;
const F_BODY: u32 = 11;
const F_MAX_TOKENS: u32 = 12;
const F_MAX_WALL_MS: u32 = 13;
const F_MAX_COST_USD_MICROS: u32 = 14;
const F_ATTACHMENTS: u32 = 15;

// Attachment field numbers
const F_ATT_NAME: u32 = 1;
const F_ATT_MIME: u32 = 2;
const F_ATT_DATA: u32 = 3;

const WIRE_VARINT: u32 = 0;
const WIRE_LEN_DELIM: u32 = 2;

// --- writer helpers --------------------------------------------------------

fn writeVarint(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, val: u64) !void {
    var v = val;
    while (v >= 0x80) {
        try buf.append(alloc, @intCast((v & 0x7F) | 0x80));
        v >>= 7;
    }
    try buf.append(alloc, @intCast(v & 0x7F));
}

fn writeTag(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, wire: u32) !void {
    try writeVarint(buf, alloc, (@as(u64, field) << 3) | @as(u64, wire));
}

fn writeString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, s: []const u8) !void {
    if (s.len == 0) return; // proto3: don't emit empty strings (default)
    try writeTag(buf, alloc, field, WIRE_LEN_DELIM);
    try writeVarint(buf, alloc, s.len);
    try buf.appendSlice(alloc, s);
}

fn writeBytes(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, b: []const u8) !void {
    // Bytes field: same wire shape as string, but we emit even when
    // empty IF caller passed non-null (we can't distinguish at this
    // layer; callers decide whether to call us).
    try writeTag(buf, alloc, field, WIRE_LEN_DELIM);
    try writeVarint(buf, alloc, b.len);
    try buf.appendSlice(alloc, b);
}

fn writeUint32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, val: u32) !void {
    if (val == 0) return; // proto3 default
    try writeTag(buf, alloc, field, WIRE_VARINT);
    try writeVarint(buf, alloc, val);
}

fn writeInt64(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, val: i64) !void {
    if (val == 0) return; // proto3 default
    try writeTag(buf, alloc, field, WIRE_VARINT);
    // int64 -> varint of the two's-complement unsigned rep
    const u: u64 = @bitCast(val);
    try writeVarint(buf, alloc, u);
}

fn writeEnum(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, field: u32, val: u32) !void {
    if (val == 0) return; // proto3 default (UNSPECIFIED)
    try writeTag(buf, alloc, field, WIRE_VARINT);
    try writeVarint(buf, alloc, val);
}

fn writeAttachment(
    outer: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    field: u32,
    att: Attachment,
) !void {
    // Build nested payload first, then length-prefix into outer.
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(alloc);

    try writeString(&inner, alloc, F_ATT_NAME, att.name);
    try writeString(&inner, alloc, F_ATT_MIME, att.mime);
    // data: length-delim even if empty so receivers know it's present.
    try writeTag(&inner, alloc, F_ATT_DATA, WIRE_LEN_DELIM);
    try writeVarint(&inner, alloc, att.data.len);
    try inner.appendSlice(alloc, att.data);

    try writeTag(outer, alloc, field, WIRE_LEN_DELIM);
    try writeVarint(outer, alloc, inner.items.len);
    try outer.appendSlice(alloc, inner.items);
}

// --- public encode ---------------------------------------------------------

/// Encode an envelope to protobuf bytes.
/// `include_sig = true`  → wire format; emits sender_sig if present.
/// `include_sig = false` → canonical bytes for signing; sender_sig
/// omitted regardless of its value.
pub fn encode(
    env: *const Envelope,
    alloc: std.mem.Allocator,
    include_sig: bool,
) PlugError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    doEncode(env, alloc, include_sig, &buf) catch return error.Internal;

    return buf.toOwnedSlice(alloc) catch return error.Internal;
}

/// Encode an envelope into its canonical byte representation used for
/// signing. Equivalent to `encode(env, alloc, include_sig=false)` but
/// named explicitly to make calling sites self-documenting. The bytes
/// returned are:
///   - stable across Zig builds (determinism test guards this)
///   - missing the `sender_sig` field even if populated
///   - exactly what ed25519 signs in envelope_sig.zig
pub fn canonicalBytes(env: *const Envelope, alloc: std.mem.Allocator) PlugError![]u8 {
    return encode(env, alloc, false);
}

fn doEncode(
    env: *const Envelope,
    alloc: std.mem.Allocator,
    include_sig: bool,
    buf: *std.ArrayList(u8),
) !void {
    // Fields emitted in ascending field-number order for determinism.
    try writeUint32(buf, alloc, F_ENVELOPE_V, env.envelope_v);
    try writeEnum(buf, alloc, F_VERB, @intFromEnum(env.verb));
    try writeString(buf, alloc, F_CONVERSATION_ID, env.conversation_id);

    if (env.in_reply_to) |s| try writeString(buf, alloc, F_IN_REPLY_TO, s);

    try writeString(buf, alloc, F_ORIGIN_CHANNEL_ID, env.origin_channel_id);
    try writeString(buf, alloc, F_SENDER_ID, env.sender_id);

    if (include_sig) {
        if (env.sender_sig) |s| try writeBytes(buf, alloc, F_SENDER_SIG, s);
    }

    try writeInt64(buf, alloc, F_SENT_AT_MS, env.sent_at_ms);

    if (env.nonce) |n| try writeBytes(buf, alloc, F_NONCE, n);

    try writeString(buf, alloc, F_BODY_MIME, env.body_mime);

    // body: emit even if empty (it's a required semantic; heartbeat
    // has empty body but body_mime set). However proto3 skips empty
    // `bytes` fields as default. We emit unconditionally because the
    // empty body still carries semantic meaning for some verbs.
    try writeTag(buf, alloc, F_BODY, WIRE_LEN_DELIM);
    try writeVarint(buf, alloc, env.body.len);
    try buf.appendSlice(alloc, env.body);

    if (env.max_tokens) |v| try writeUint32(buf, alloc, F_MAX_TOKENS, v);
    if (env.max_wall_ms) |v| try writeUint32(buf, alloc, F_MAX_WALL_MS, v);
    if (env.max_cost_usd_micros) |v| try writeUint32(buf, alloc, F_MAX_COST_USD_MICROS, v);

    for (env.attachments) |att| {
        try writeAttachment(buf, alloc, F_ATTACHMENTS, att);
    }
}

// --- reader helpers --------------------------------------------------------

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn hasMore(self: *Reader) bool {
        return self.pos < self.bytes.len;
    }

    fn readVarint(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.bytes.len) return error.Truncated;
            const b = self.bytes[self.pos];
            self.pos += 1;
            result |= (@as(u64, b & 0x7F)) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            if (shift >= 64) return error.VarintTooLong;
        }
        return result;
    }

    fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// Skip a field we don't recognize. Required for forward-compat
    /// with v1-reserved fields and future envelope versions.
    fn skipField(self: *Reader, wire: u32) !void {
        switch (wire) {
            WIRE_VARINT => {
                _ = try self.readVarint();
            },
            WIRE_LEN_DELIM => {
                const len = try self.readVarint();
                _ = try self.readBytes(@intCast(len));
            },
            1 => { // 64-bit fixed — skip 8 bytes
                _ = try self.readBytes(8);
            },
            5 => { // 32-bit fixed — skip 4 bytes
                _ = try self.readBytes(4);
            },
            else => return error.UnknownWireType,
        }
    }
};

// --- public decode ---------------------------------------------------------

/// Decode protobuf bytes into an Envelope. All slice fields in the
/// returned value point into `bytes` — callers must keep `bytes`
/// alive for the lifetime of the envelope (or dupe what they need).
/// Attachments are allocated in `alloc`.
pub fn decode(bytes: []const u8, alloc: std.mem.Allocator) PlugError!Envelope {
    var r = Reader{ .bytes = bytes };

    // Collect attachments in a dynamic list since we don't know the
    // count up front.
    var attachments_list: std.ArrayList(Attachment) = .empty;
    errdefer attachments_list.deinit(alloc);

    var env = Envelope{
        .envelope_v = 0, // populated below; we validate != 0 at end
        .verb = .unspecified,
        .conversation_id = "",
        .origin_channel_id = "",
        .sender_id = "",
        .sent_at_ms = 0,
        .body = "",
    };
    var saw_conv = false;
    var saw_origin = false;
    var saw_sender = false;

    while (r.hasMore()) {
        const tag = r.readVarint() catch return error.BadInput;
        const field: u32 = @intCast(tag >> 3);
        const wire: u32 = @intCast(tag & 0x7);

        switch (field) {
            F_ENVELOPE_V => env.envelope_v = @intCast(r.readVarint() catch return error.BadInput),
            F_VERB => {
                const v = r.readVarint() catch return error.BadInput;
                env.verb = verbFromInt(@intCast(v)) catch return error.BadInput;
            },
            F_CONVERSATION_ID => {
                env.conversation_id = readString(&r) catch return error.BadInput;
                saw_conv = true;
            },
            F_IN_REPLY_TO => env.in_reply_to = readString(&r) catch return error.BadInput,
            F_ORIGIN_CHANNEL_ID => {
                env.origin_channel_id = readString(&r) catch return error.BadInput;
                saw_origin = true;
            },
            F_SENDER_ID => {
                env.sender_id = readString(&r) catch return error.BadInput;
                saw_sender = true;
            },
            F_SENDER_SIG => env.sender_sig = readString(&r) catch return error.BadInput,
            F_SENT_AT_MS => {
                const u = r.readVarint() catch return error.BadInput;
                env.sent_at_ms = @bitCast(u);
            },
            F_NONCE => env.nonce = readString(&r) catch return error.BadInput,
            F_BODY_MIME => env.body_mime = readString(&r) catch return error.BadInput,
            F_BODY => env.body = readString(&r) catch return error.BadInput,
            F_MAX_TOKENS => env.max_tokens = @intCast(r.readVarint() catch return error.BadInput),
            F_MAX_WALL_MS => env.max_wall_ms = @intCast(r.readVarint() catch return error.BadInput),
            F_MAX_COST_USD_MICROS => env.max_cost_usd_micros = @intCast(r.readVarint() catch return error.BadInput),
            F_ATTACHMENTS => {
                const payload = readString(&r) catch return error.BadInput;
                const att = decodeAttachment(payload) catch return error.BadInput;
                attachments_list.append(alloc, att) catch return error.Internal;
            },
            else => r.skipField(wire) catch return error.BadInput,
        }
    }

    // Sanity checks on required fields. envelope_v is allowed here to
    // be any value; version-gating is a separate pass (TIG-151).
    // Double-free guard: errdefer above calls deinit on error path;
    // we don't free here, just return and let errdefer handle it.
    // Body is NOT required — proto3 defaults an unset bytes field to
    // empty, and verbs like HEARTBEAT legitimately have empty body.
    if (!saw_conv or !saw_origin or !saw_sender) {
        return error.BadInput;
    }
    if (env.verb == .unspecified) {
        return error.BadInput;
    }

    env.attachments = attachments_list.toOwnedSlice(alloc) catch return error.Internal;
    return env;
}

fn readString(r: *Reader) ![]const u8 {
    const len = try r.readVarint();
    return r.readBytes(@intCast(len));
}

fn verbFromInt(v: u32) !Verb {
    return switch (v) {
        0 => .unspecified,
        1 => .user_msg,
        2 => .tool_call,
        3 => .tool_result,
        4 => .reply,
        5 => .retract,
        6 => .hello,
        7 => .hello_ack,
        8 => .refuse,
        9 => .heartbeat,
        else => error.UnknownVerb,
    };
}

fn decodeAttachment(bytes: []const u8) !Attachment {
    var r = Reader{ .bytes = bytes };
    var att = Attachment{ .name = "", .mime = "", .data = "" };
    while (r.hasMore()) {
        const tag = try r.readVarint();
        const field: u32 = @intCast(tag >> 3);
        const wire: u32 = @intCast(tag & 0x7);
        switch (field) {
            F_ATT_NAME => att.name = try readString(&r),
            F_ATT_MIME => att.mime = try readString(&r),
            F_ATT_DATA => att.data = try readString(&r),
            else => try r.skipField(wire),
        }
    }
    return att;
}

/// Free the attachments slice allocated by decode(). Other slice
/// fields point into the source buffer; caller manages that lifetime.
pub fn deinitDecoded(env: *Envelope, alloc: std.mem.Allocator) void {
    if (env.attachments.len > 0) {
        alloc.free(env.attachments);
        env.attachments = &.{};
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeMinimal() Envelope {
    return .{
        .verb = .user_msg,
        .conversation_id = "conv-01",
        .origin_channel_id = "chan-cli:local",
        .sender_id = "user:omkar",
        .sent_at_ms = 1745000000000,
        .body_mime = "application/json",
        .body = "{\"text\":\"hi\"}",
    };
}

test "roundtrip: minimal user_msg envelope" {
    const env = makeMinimal();
    const bytes = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(bytes);

    var decoded = try decode(bytes, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);

    try testing.expectEqual(@as(u32, 1), decoded.envelope_v);
    try testing.expectEqual(Verb.user_msg, decoded.verb);
    try testing.expectEqualStrings("conv-01", decoded.conversation_id);
    try testing.expectEqualStrings("chan-cli:local", decoded.origin_channel_id);
    try testing.expectEqualStrings("user:omkar", decoded.sender_id);
    try testing.expectEqual(@as(i64, 1745000000000), decoded.sent_at_ms);
    try testing.expectEqualStrings("application/json", decoded.body_mime);
    try testing.expectEqualStrings("{\"text\":\"hi\"}", decoded.body);
    try testing.expectEqual(@as(usize, 0), decoded.attachments.len);
}

test "roundtrip: all optional fields populated" {
    var env = makeMinimal();
    env.in_reply_to = "env-prev";
    env.sender_sig = "SIGSIGSIG";
    env.nonce = "abcdef";
    env.max_tokens = 4000;
    env.max_wall_ms = 30000;
    env.max_cost_usd_micros = 12345;

    const bytes = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(bytes);

    var decoded = try decode(bytes, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);

    try testing.expect(decoded.in_reply_to != null);
    try testing.expectEqualStrings("env-prev", decoded.in_reply_to.?);
    try testing.expect(decoded.sender_sig != null);
    try testing.expectEqualStrings("SIGSIGSIG", decoded.sender_sig.?);
    try testing.expect(decoded.nonce != null);
    try testing.expectEqualStrings("abcdef", decoded.nonce.?);
    try testing.expectEqual(@as(?u32, 4000), decoded.max_tokens);
    try testing.expectEqual(@as(?u32, 30000), decoded.max_wall_ms);
    try testing.expectEqual(@as(?u32, 12345), decoded.max_cost_usd_micros);
}

test "roundtrip: with attachments" {
    const atts = [_]Attachment{
        .{ .name = "a.txt", .mime = "text/plain", .data = "hello" },
        .{ .name = "b.png", .mime = "image/png", .data = "\x89PNG..." },
    };
    var env = makeMinimal();
    env.attachments = &atts;

    const bytes = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(bytes);

    var decoded = try decode(bytes, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);

    try testing.expectEqual(@as(usize, 2), decoded.attachments.len);
    try testing.expectEqualStrings("a.txt", decoded.attachments[0].name);
    try testing.expectEqualStrings("text/plain", decoded.attachments[0].mime);
    try testing.expectEqualStrings("hello", decoded.attachments[0].data);
    try testing.expectEqualStrings("b.png", decoded.attachments[1].name);
}

test "encode: include_sig=false omits sender_sig" {
    var env = makeMinimal();
    env.sender_sig = "XXXXSIGXXXX";

    const wire_bytes = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(wire_bytes);
    const canon_bytes = try encode(&env, testing.allocator, false);
    defer testing.allocator.free(canon_bytes);

    // Canonical must be shorter — missing the sig field + its tag.
    try testing.expect(canon_bytes.len < wire_bytes.len);

    // Decoding canonical should produce env with no sig populated.
    var decoded = try decode(canon_bytes, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), decoded.sender_sig);
}

test "decode: rejects missing sender_id" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try writeUint32(&buf, testing.allocator, F_ENVELOPE_V, 1);
    try writeEnum(&buf, testing.allocator, F_VERB, 1);
    try writeString(&buf, testing.allocator, F_CONVERSATION_ID, "c");
    try writeString(&buf, testing.allocator, F_ORIGIN_CHANNEL_ID, "o");
    // (no sender_id)
    try writeInt64(&buf, testing.allocator, F_SENT_AT_MS, 1);
    try writeString(&buf, testing.allocator, F_BODY_MIME, "application/json");

    const result = decode(buf.items, testing.allocator);
    try testing.expectError(error.BadInput, result);
}

test "decode: rejects missing verb" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try writeUint32(&buf, testing.allocator, F_ENVELOPE_V, 1);
    // (no verb — proto3 default UNSPECIFIED=0 is rejected)
    try writeString(&buf, testing.allocator, F_CONVERSATION_ID, "c");
    try writeString(&buf, testing.allocator, F_ORIGIN_CHANNEL_ID, "o");
    try writeString(&buf, testing.allocator, F_SENDER_ID, "s");
    try writeInt64(&buf, testing.allocator, F_SENT_AT_MS, 1);
    try writeString(&buf, testing.allocator, F_BODY_MIME, "application/json");

    const result = decode(buf.items, testing.allocator);
    try testing.expectError(error.BadInput, result);
}

test "decode: rejects truncated input" {
    var env = makeMinimal();
    const full = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(full);

    // Cut the middle of the buffer.
    const truncated = full[0 .. full.len / 2];
    const result = decode(truncated, testing.allocator);
    try testing.expectError(error.BadInput, result);
}

test "decode: skips unknown fields (forward-compat with reserved range)" {
    var env = makeMinimal();
    const bytes = try encode(&env, testing.allocator, true);
    defer testing.allocator.free(bytes);

    // Prepend a tag for a v1-reserved field (field 50, varint wire
    // type). A future schema might add it; v1 decoders must tolerate
    // and skip.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeTag(&buf, testing.allocator, 50, WIRE_VARINT);
    try writeVarint(&buf, testing.allocator, 999);
    try buf.appendSlice(testing.allocator, bytes);

    var decoded = try decode(buf.items, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);

    // Original fields still decoded correctly.
    try testing.expectEqualStrings("conv-01", decoded.conversation_id);
}

// Fixture bytes embedded at compile time — tests don't depend on CWD.
// These live in src/envelope_fixtures/ (mirroring spec/fixtures/envelope/)
// because @embedFile requires paths within the module's package root.
const fixtures = struct {
    const user_msg = @embedFile("envelope_fixtures/user_msg.pb.bin");
    const tool_call = @embedFile("envelope_fixtures/tool_call.pb.bin");
    const tool_result = @embedFile("envelope_fixtures/tool_result.pb.bin");
    const reply = @embedFile("envelope_fixtures/reply.pb.bin");
    const retract = @embedFile("envelope_fixtures/retract.pb.bin");
    const hello = @embedFile("envelope_fixtures/hello.pb.bin");
    const hello_ack = @embedFile("envelope_fixtures/hello_ack.pb.bin");
    const refuse = @embedFile("envelope_fixtures/refuse.pb.bin");
    const heartbeat = @embedFile("envelope_fixtures/heartbeat.pb.bin");
};

test "fixture: user_msg.pb.bin decodes to expected content" {
    var decoded = try decode(fixtures.user_msg, testing.allocator);
    defer deinitDecoded(&decoded, testing.allocator);

    try testing.expectEqual(Verb.user_msg, decoded.verb);
    try testing.expectEqualStrings("conv-01", decoded.conversation_id);
    try testing.expectEqualStrings("user:omkar", decoded.sender_id);
    try testing.expectEqualStrings("{\"text\":\"hi\"}", decoded.body);
}

test "canonicalBytes: deterministic across calls" {
    var env = makeMinimal();
    env.sender_sig = "TEST_SIG_VALUE";

    const bytes_a = try canonicalBytes(&env, testing.allocator);
    defer testing.allocator.free(bytes_a);

    const bytes_b = try canonicalBytes(&env, testing.allocator);
    defer testing.allocator.free(bytes_b);

    try testing.expectEqualSlices(u8, bytes_a, bytes_b);
}

test "canonicalBytes: omits sender_sig even when populated" {
    var env_with_sig = makeMinimal();
    env_with_sig.sender_sig = "DIFFERENT_SIG";

    var env_without_sig = makeMinimal();
    env_without_sig.sender_sig = null;

    const canon_with = try canonicalBytes(&env_with_sig, testing.allocator);
    defer testing.allocator.free(canon_with);

    const canon_without = try canonicalBytes(&env_without_sig, testing.allocator);
    defer testing.allocator.free(canon_without);

    // Whether the envelope's sender_sig is set or not, the canonical
    // bytes must be byte-identical — the field is excluded from signing.
    try testing.expectEqualSlices(u8, canon_with, canon_without);
}

test "canonicalBytes: signature changes don't affect canonical output" {
    var env = makeMinimal();

    env.sender_sig = "SIG_A";
    const with_a = try canonicalBytes(&env, testing.allocator);
    defer testing.allocator.free(with_a);

    env.sender_sig = "SIG_B_LONGER";
    const with_b = try canonicalBytes(&env, testing.allocator);
    defer testing.allocator.free(with_b);

    try testing.expectEqualSlices(u8, with_a, with_b);
}

test "canonicalBytes: body content DOES affect canonical output" {
    var env_a = makeMinimal();
    env_a.body = "{\"text\":\"hi\"}";

    var env_b = makeMinimal();
    env_b.body = "{\"text\":\"bye\"}";

    const canon_a = try canonicalBytes(&env_a, testing.allocator);
    defer testing.allocator.free(canon_a);

    const canon_b = try canonicalBytes(&env_b, testing.allocator);
    defer testing.allocator.free(canon_b);

    // Different body → different canonical bytes. This is what makes
    // the signature catch tampering.
    try testing.expect(!std.mem.eql(u8, canon_a, canon_b));
}

test "canonicalBytes: all 9 fixture verbs produce deterministic output" {
    const cases = [_][]const u8{
        fixtures.user_msg,    fixtures.tool_call,
        fixtures.tool_result, fixtures.reply,
        fixtures.retract,     fixtures.hello,
        fixtures.hello_ack,   fixtures.refuse,
        fixtures.heartbeat,
    };

    for (cases) |bytes| {
        var decoded = try decode(bytes, testing.allocator);
        defer deinitDecoded(&decoded, testing.allocator);

        // Two canonicalizations of the same envelope must be identical.
        const pass1 = try canonicalBytes(&decoded, testing.allocator);
        defer testing.allocator.free(pass1);
        const pass2 = try canonicalBytes(&decoded, testing.allocator);
        defer testing.allocator.free(pass2);

        try testing.expectEqualSlices(u8, pass1, pass2);
    }
}

test "fixture: all 9 verb fixtures decode successfully" {
    const cases = [_]struct { bytes: []const u8, verb: Verb }{
        .{ .bytes = fixtures.user_msg, .verb = .user_msg },
        .{ .bytes = fixtures.tool_call, .verb = .tool_call },
        .{ .bytes = fixtures.tool_result, .verb = .tool_result },
        .{ .bytes = fixtures.reply, .verb = .reply },
        .{ .bytes = fixtures.retract, .verb = .retract },
        .{ .bytes = fixtures.hello, .verb = .hello },
        .{ .bytes = fixtures.hello_ack, .verb = .hello_ack },
        .{ .bytes = fixtures.refuse, .verb = .refuse },
        .{ .bytes = fixtures.heartbeat, .verb = .heartbeat },
    };

    for (cases) |c| {
        var decoded = try decode(c.bytes, testing.allocator);
        defer deinitDecoded(&decoded, testing.allocator);

        try testing.expectEqual(c.verb, decoded.verb);
        try testing.expectEqual(@as(u32, 1), decoded.envelope_v);
    }
}
