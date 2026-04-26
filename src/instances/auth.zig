//! Per-instance bearer token primitives.
//!
//! Each registered instance (TUI, CLI, future web client) owns one
//! random 32-byte bearer token. The token is shown to the client
//! exactly once — at registration — and never persisted in the
//! clear. The database holds only its Blake3 digest, so a disclosed
//! row cannot impersonate the instance.
//!
//! The hash is full-width Blake3 (32 bytes → 64 hex chars). Tokens
//! are auth credentials; there is no reason to truncate. The wire
//! form of both the token and the hash is lowercase hex.

const std = @import("std");

/// 32-byte random token rendered as 64 lowercase hex chars. Generated
/// from `std.crypto.random` at registration; the gateway returns the
/// hex form to the client once and never stores it.
pub const Token = [token_hex_len]u8;
pub const token_hex_len = 64;

/// Blake3 digest of a token, rendered as 64 lowercase hex chars.
/// What the database stores; what `findByTokenHash` looks up.
pub const TokenHash = [token_hex_len]u8;

const hex_chars = "0123456789abcdef";

/// Generate a fresh per-instance token. Uses the platform's
/// crypto-secure RNG via `std.Io.randomSecure`; never returns a
/// predictable value across calls. Returns `error.EntropyUnavailable`
/// when the OS has no entropy source — the registration route maps
/// this to a 503.
pub fn generate(io: std.Io) std.Io.RandomSecureError!Token {
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    return encodeHex(raw);
}

/// Random instance id rendered as `<kind>-<8 lowercase hex chars>`,
/// max 13 bytes. Mirrors the wire form the tests already use
/// (`tui-bbbbbbbb`). Buffer must be at least `kind.len + 1 + 8` bytes.
pub fn genInstanceId(io: std.Io, buf: []u8, kind: []const u8) std.Io.RandomSecureError![]u8 {
    var raw: [4]u8 = undefined;
    try io.randomSecure(&raw);
    var i: usize = 0;
    @memcpy(buf[i..][0..kind.len], kind);
    i += kind.len;
    buf[i] = '-';
    i += 1;
    for (raw) |b| {
        buf[i] = hex_chars[(b >> 4) & 0xF];
        buf[i + 1] = hex_chars[b & 0xF];
        i += 2;
    }
    return buf[0..i];
}

/// Hash a token (presented over the wire) into the form stored in
/// the `token_hash` column. The input is hex; the output is hex.
pub fn hash(token: []const u8) TokenHash {
    var raw: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(token, &raw, .{});
    return encodeHex(raw);
}

fn encodeHex(raw: [32]u8) [token_hex_len]u8 {
    var out: [token_hex_len]u8 = undefined;
    for (raw, 0..) |b, i| {
        out[i * 2 + 0] = hex_chars[(b >> 4) & 0xF];
        out[i * 2 + 1] = hex_chars[b & 0xF];
    }
    return out;
}

/// Constant-time-ish equality for a presented token hash and the
/// stored value. Avoids leaking the prefix length via short-circuit
/// timing. The cost over a network is negligible compared to the
/// difference between a one-byte mismatch and a full match, but the
/// pattern is cheap and worth applying everywhere a credential
/// comparison happens.
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "generate: produces 64 lowercase hex chars" {
    const t = try generate(testing.io);
    try testing.expectEqual(@as(usize, 64), t.len);
    for (t) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "generate: two calls produce different tokens" {
    const a = try generate(testing.io);
    const b = try generate(testing.io);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hash: deterministic for the same input" {
    const a = hash("hello");
    const b = hash("hello");
    try testing.expectEqualSlices(u8, &a, &b);
}

test "hash: different inputs produce different digests" {
    const a = hash("hello");
    const b = hash("world");
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hash: digest is 64 lowercase hex chars" {
    const h = hash("anything");
    try testing.expectEqual(@as(usize, 64), h.len);
    for (h) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "constantTimeEql: matches on identical inputs" {
    try testing.expect(constantTimeEql("abc", "abc"));
}

test "constantTimeEql: rejects differing lengths" {
    try testing.expect(!constantTimeEql("abc", "abcd"));
}

test "constantTimeEql: rejects differing bytes" {
    try testing.expect(!constantTimeEql("abc", "abd"));
}

test "genInstanceId: shape is <kind>-<8 hex>" {
    var buf: [16]u8 = undefined;
    const id = try genInstanceId(testing.io, &buf, "tui");
    try testing.expectEqual(@as(usize, 12), id.len);
    try testing.expectEqualStrings("tui-", id[0..4]);
    for (id[4..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "genInstanceId: distinct calls produce distinct ids" {
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    const a = try genInstanceId(testing.io, &b1, "cli");
    const b = try genInstanceId(testing.io, &b2, "cli");
    try testing.expect(!std.mem.eql(u8, a, b));
}
