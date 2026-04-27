//! Ed25519 signing + verification for envelopes.
//!
//! Signs canonicalBytes(envelope) via std.crypto.sign.Ed25519. The
//! signature goes into the envelope's sender_sig field; verification
//! re-canonicalizes and checks the signature holds.
//!
//! Key pair storage (loadFromFile / saveToFile) will land as part of
//! the persona plug in Phase 2/3. This module is pure crypto + the
//! canonical-bytes bridge.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.trust-boundary

const std = @import("std");
const codec = @import("envelope_codec.zig");
const envelope_mod = @import("envelope.zig");
const errors = @import("errors");

const Envelope = envelope_mod.Envelope;
const PlugError = errors.PlugError;
const Ed25519 = std.crypto.sign.Ed25519;

pub const public_key_len: usize = Ed25519.PublicKey.encoded_length;
pub const secret_key_len: usize = Ed25519.SecretKey.encoded_length;
pub const signature_len: usize = Ed25519.Signature.encoded_length;

pub const KeyPair = Ed25519.KeyPair;

/// Generate a fresh keypair. Uses the CSPRNG wired into `io`.
pub fn generate(io: std.Io) PlugError!KeyPair {
    return KeyPair.generate(io);
}

/// Produce ed25519 signature over canonicalBytes(env). Caller owns
/// the returned slice; it is `alloc`-allocated and signature_len bytes.
pub fn signCanonical(
    env: *const Envelope,
    kp: KeyPair,
    alloc: std.mem.Allocator,
) PlugError![]u8 {
    const canonical = try codec.canonicalBytes(env, alloc);
    defer alloc.free(canonical);

    const sig = kp.sign(canonical, null) catch return error.Internal;
    const encoded = sig.toBytes();

    const out = alloc.alloc(u8, signature_len) catch return error.Internal;
    @memcpy(out, &encoded);
    return out;
}

/// Sign an envelope in place: attaches the signature bytes to
/// env.sender_sig. Caller owns the allocated signature slice and must
/// free it (typically via alloc's arena at turn end).
pub fn signInPlace(
    env: *Envelope,
    kp: KeyPair,
    alloc: std.mem.Allocator,
) PlugError!void {
    const sig = try signCanonical(env, kp, alloc);
    env.sender_sig = sig;
}

/// Verify that the signature in env.sender_sig is a valid ed25519
/// signature over canonicalBytes(env) produced by `public_key`.
///
/// Returns:
///   true   — signature valid
///   false  — no signature OR invalid
///
/// A missing sender_sig field returns false (fail-closed). A malformed
/// signature returns BadInput.
pub fn verify(
    env: *const Envelope,
    public_key: [public_key_len]u8,
    alloc: std.mem.Allocator,
) PlugError!bool {
    const sig_bytes = env.sender_sig orelse return false;
    if (sig_bytes.len != signature_len) return error.BadInput;

    const canonical = try codec.canonicalBytes(env, alloc);
    defer alloc.free(canonical);

    var sig_array: [signature_len]u8 = undefined;
    @memcpy(&sig_array, sig_bytes);

    const pk = Ed25519.PublicKey.fromBytes(public_key) catch return error.BadInput;
    const sig = Ed25519.Signature.fromBytes(sig_array);

    sig.verify(canonical, pk) catch return false;
    return true;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeTestEnvelope() Envelope {
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

test "generate: produces a valid keypair" {
    const kp = try generate(std.testing.io);
    // public_key bytes should be 32 bytes of "real" data (not all zero).
    const pk = kp.public_key.toBytes();
    var all_zero = true;
    for (pk) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);
}

test "sign + verify: roundtrip succeeds" {
    const kp = try generate(std.testing.io);
    var env = makeTestEnvelope();

    try signInPlace(&env, kp, testing.allocator);
    defer if (env.sender_sig) |s| testing.allocator.free(s);

    const ok = try verify(&env, kp.public_key.toBytes(), testing.allocator);
    try testing.expect(ok);
}

test "verify: tampered body fails" {
    const kp = try generate(std.testing.io);
    var env = makeTestEnvelope();

    try signInPlace(&env, kp, testing.allocator);
    defer if (env.sender_sig) |s| testing.allocator.free(s);

    // Swap body after signing.
    env.body = "{\"text\":\"ATTACKER\"}";

    const ok = try verify(&env, kp.public_key.toBytes(), testing.allocator);
    try testing.expect(!ok);
}

test "verify: wrong public key fails" {
    const kp_a = try generate(std.testing.io);
    const kp_b = try generate(std.testing.io);

    var env = makeTestEnvelope();
    try signInPlace(&env, kp_a, testing.allocator);
    defer if (env.sender_sig) |s| testing.allocator.free(s);

    // Verify against b's public key — should fail.
    const ok = try verify(&env, kp_b.public_key.toBytes(), testing.allocator);
    try testing.expect(!ok);
}

test "verify: missing sender_sig returns false" {
    const kp = try generate(std.testing.io);
    const env = makeTestEnvelope();
    // No signInPlace call — sender_sig remains null.
    const ok = try verify(&env, kp.public_key.toBytes(), testing.allocator);
    try testing.expect(!ok);
}

test "verify: malformed signature length returns BadInput" {
    const kp = try generate(std.testing.io);
    var env = makeTestEnvelope();
    env.sender_sig = "too-short"; // not 64 bytes

    try testing.expectError(error.BadInput, verify(&env, kp.public_key.toBytes(), testing.allocator));
}

test "sign: same envelope twice produces same signature (canonical bytes stable)" {
    // ed25519 signing is deterministic (RFC 8032), so signing the
    // SAME canonical bytes with the SAME key must return the SAME
    // signature. This doubles as a proof that canonicalBytes is
    // deterministic enough for signing.
    const kp = try generate(std.testing.io);
    var env1 = makeTestEnvelope();
    var env2 = makeTestEnvelope();

    const sig1 = try signCanonical(&env1, kp, testing.allocator);
    defer testing.allocator.free(sig1);
    const sig2 = try signCanonical(&env2, kp, testing.allocator);
    defer testing.allocator.free(sig2);

    try testing.expectEqualSlices(u8, sig1, sig2);
}

test "signature excludes sender_sig itself (canonical property)" {
    // A signature is over canonical bytes (sender_sig excluded). If
    // we sign an envelope, then STAMP a different signature into
    // sender_sig, then verify with the original signature — verify
    // should STILL pass because sender_sig isn't part of the signed
    // content.
    //
    // This test guards against accidentally including sender_sig in
    // the canonical output (which would make the signature chase its
    // own tail).
    const kp = try generate(std.testing.io);
    var env = makeTestEnvelope();

    const original_sig = try signCanonical(&env, kp, testing.allocator);
    defer testing.allocator.free(original_sig);

    // Mutate sender_sig to something random.
    env.sender_sig = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567890+";
    // ... now install the ACTUAL signature and verify.
    env.sender_sig = original_sig;

    const ok = try verify(&env, kp.public_key.toBytes(), testing.allocator);
    try testing.expect(ok);
}
