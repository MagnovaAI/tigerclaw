//! Determinism primitives.
//!
//! Every source of non-determinism in the runtime — RNG, IDs, ordering —
//! must be seedable. Tests set `fixed_seed`; production draws from the OS.
//!
//! This module only provides an RNG. ID generation and other helpers sit in
//! `util/` (added later) and take a `*std.Random` from here.

const std = @import("std");

pub const Seed = u64;

/// Returned for a test-stable sequence.
pub const fixed_seed: Seed = 0xDEADBEEF_CAFEBABE;

pub const Rng = struct {
    prng: std.Random.DefaultPrng,

    pub fn initSeeded(seed: Seed) Rng {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Production entry point: mix OS entropy into the seed so runs differ.
    pub fn initFromOs() Rng {
        var seed: Seed = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn random(self: *Rng) std.Random {
        return self.prng.random();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "initSeeded: same seed yields identical sequences" {
    var a = Rng.initSeeded(fixed_seed);
    var b = Rng.initSeeded(fixed_seed);
    const ra = a.random();
    const rb = b.random();
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try testing.expectEqual(ra.int(u64), rb.int(u64));
    }
}

test "initSeeded: different seeds diverge within a handful of draws" {
    var a = Rng.initSeeded(1);
    var b = Rng.initSeeded(2);
    const ra = a.random();
    const rb = b.random();
    var diverged = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (ra.int(u64) != rb.int(u64)) {
            diverged = true;
            break;
        }
    }
    try testing.expect(diverged);
}

test "random(): reused reference continues the same sequence" {
    var rng = Rng.initSeeded(fixed_seed);
    const r1 = rng.random();
    const a = r1.int(u32);
    const r2 = rng.random();
    const b = r2.int(u32);
    // The two draws come from the same stream, so they should differ in
    // almost all cases — this is a sanity check, not cryptographic.
    try testing.expect(a != b);
}
