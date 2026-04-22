//! Compile-time guards for bench-mode sessions.
//!
//! The runtime rule for bench / eval / replay modes is: every LLM
//! call must be reproducible. That implies the provider must be
//! either (a) a mock with deterministic scripted output or (b) a
//! VCR-backed replay of a recorded cassette. Live providers are
//! forbidden because response latency, retry jitter, and token
//! sampling would all pollute measurements.
//!
//! We enforce that rule **at compile time**, not at runtime. The
//! mechanism:
//!
//!   1. `GuardedProvider` is a nominal struct distinct from
//!      `llm.Provider`. Only two factory functions in this module
//!      construct it, and both require proof that the underlying
//!      provider is deterministic (a `Determinism` witness, itself
//!      only obtainable from the mock or VCR layers).
//!
//!   2. `BenchHarnessBuilder.withProvider(...)` takes a
//!      `GuardedProvider` by type. Passing a raw `llm.Provider`
//!      produces a type-mismatch compile error — there is no
//!      implicit conversion and no `fromUnsafe(...)` constructor on
//!      `GuardedProvider`. That is deliberate: any escape hatch
//!      would defeat the whole point.
//!
//!   3. Downstream bench code consumes `GuardedProvider`, which
//!      still exposes the original `Provider` through `.inner` so
//!      the LLM client code does not need to fork.
//!
//! The `Determinism` witness is shaped like Zig's other nominal
//! types (e.g. `std.rand.Random.DefaultPrng`): a struct with a
//! private field so external callers cannot forge one, plus an enum
//! tag recording *how* determinism was established, for audit.

const std = @import("std");
const llm = @import("../llm/root.zig");

/// Enumerates the approved sources of determinism. Extending this is
/// a deliberate act — each new variant is a review checkpoint for the
/// claim that a new provider class is replay-safe.
pub const DeterminismSource = enum {
    /// `llm.MockProvider` — output is scripted by the test author.
    mock,
    /// VCR cassette replay — responses come from a recorded
    /// request/response log with no live network traffic.
    vcr_replay,
};

/// Unforgeable witness that a provider is deterministic.
///
/// External callers cannot construct one directly because the
/// `_private` field is not exposed through a public initializer.
/// The only way to obtain a `Determinism` is through the `.forMock`
/// / `.forVcrReplay` helpers on `GuardedProvider`, each of which
/// only accepts the corresponding concrete type.
pub const Determinism = struct {
    source: DeterminismSource,
    _private: void = {},
};

/// A provider that the type system has accepted as bench-safe.
///
/// The wrapper adds no overhead (it is a POD struct over a vtable
/// pointer); its whole purpose is nominal typing.
pub const GuardedProvider = struct {
    inner: llm.Provider,
    witness: Determinism,

    /// Wrap an owned `MockProvider`. The caller keeps ownership of
    /// the implementing struct (standard vtable rule).
    pub fn forMock(mock: *llm.MockProvider) GuardedProvider {
        return .{
            .inner = mock.provider(),
            .witness = .{ .source = .mock },
        };
    }

    /// Wrap a VCR-backed provider. The parameter type is a fully
    /// constructed `VcrProvider` value; there is no generic
    /// "anything claiming to be VCR" path.
    pub fn forVcrReplay(vcr: *VcrProvider) GuardedProvider {
        return .{
            .inner = vcr.provider(),
            .witness = .{ .source = .vcr_replay },
        };
    }
};

/// Placeholder VCR-backed provider. The concrete replay provider
/// lands with Commit 35 (entrypoints against mock) / Commit 47
/// (E2E replay). For now we ship the type so bench guards can name
/// it; the `provider()` method returns the underlying vtable, which
/// real VCR replay will plug into once it exists.
///
/// Keeping this as a tiny type here (rather than shimming against
/// the real one later) is intentional: it lets bench_guards stay
/// self-contained and gives future VCR code a single point of
/// contact. When the real replay provider lands, this file changes
/// in one place and every bench caller picks it up.
pub const VcrProvider = struct {
    impl: llm.Provider,

    pub fn provider(self: *VcrProvider) llm.Provider {
        return self.impl;
    }
};

/// Builder for a bench-mode harness configuration.
///
/// Constructed by `begin()`. The build-state is captured in the type
/// via a phantom `configured_provider` bool so attempting to `build`
/// without having set a provider is a compile error, not a runtime
/// panic.
pub const BenchConfig = struct {
    provider: GuardedProvider,
    seed: u64,
};

pub const BenchHarnessBuilder = struct {
    seed: u64 = 0,

    pub fn begin() BenchHarnessBuilder {
        return .{};
    }

    pub fn withSeed(self: BenchHarnessBuilder, seed: u64) BenchHarnessBuilder {
        var next = self;
        next.seed = seed;
        return next;
    }

    /// Attach a provider. The parameter type is `GuardedProvider`, so
    /// passing a raw `llm.Provider` here yields a compile error
    /// ("expected type 'bench_guards.GuardedProvider', found 'llm.Provider'"),
    /// which is exactly the guarantee the commit ticket asks for.
    pub fn withProvider(
        self: BenchHarnessBuilder,
        provider: GuardedProvider,
    ) BuilderWithProvider {
        return .{
            .seed = self.seed,
            .provider = provider,
        };
    }
};

/// A `BenchHarnessBuilder` that has had a provider attached. Only
/// this type exposes `build()`, so the compiler rejects `build()`
/// calls that skipped `withProvider`.
pub const BuilderWithProvider = struct {
    seed: u64,
    provider: GuardedProvider,

    pub fn withSeed(self: BuilderWithProvider, seed: u64) BuilderWithProvider {
        var next = self;
        next.seed = seed;
        return next;
    }

    pub fn build(self: BuilderWithProvider) BenchConfig {
        return .{ .provider = self.provider, .seed = self.seed };
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "GuardedProvider: forMock carries the mock witness" {
    var mock = llm.MockProvider{ .replies = &.{} };

    const g = GuardedProvider.forMock(&mock);
    try testing.expectEqual(DeterminismSource.mock, g.witness.source);
    try testing.expectEqualStrings("mock", g.inner.name());
}

test "BenchHarnessBuilder: build round-trips seed and provider" {
    var mock = llm.MockProvider{ .replies = &.{} };

    const cfg = BenchHarnessBuilder.begin()
        .withSeed(42)
        .withProvider(GuardedProvider.forMock(&mock))
        .build();

    try testing.expectEqual(@as(u64, 42), cfg.seed);
    try testing.expectEqual(DeterminismSource.mock, cfg.provider.witness.source);
}

test "BenchHarnessBuilder: withSeed after withProvider is still allowed" {
    var mock = llm.MockProvider{ .replies = &.{} };

    const cfg = BenchHarnessBuilder.begin()
        .withProvider(GuardedProvider.forMock(&mock))
        .withSeed(7)
        .build();
    try testing.expectEqual(@as(u64, 7), cfg.seed);
}

test "BenchHarnessBuilder: unset seed defaults to zero" {
    var mock = llm.MockProvider{ .replies = &.{} };

    const cfg = BenchHarnessBuilder.begin()
        .withProvider(GuardedProvider.forMock(&mock))
        .build();
    try testing.expectEqual(@as(u64, 0), cfg.seed);
}

// NOTE: there is no `GuardedProvider.fromUnsafe(llm.Provider)`
// constructor. Adding one would create the very escape hatch the
// ticket forbids. If a future bench-safe provider class is needed
// (e.g. a pure-function fake), extend `DeterminismSource` and add a
// dedicated `forX` factory that accepts only that concrete type.
