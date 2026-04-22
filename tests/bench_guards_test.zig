//! Integration tests for bench-mode provider guards.
//!
//! The central claim these tests defend:
//!
//!   > Passing an unguarded `llm.Provider` to `BenchHarnessBuilder`
//!   > must fail at compile time — no runtime escape hatch exists.
//!
//! We cannot literally compile the negative case from inside a
//! test (the whole test binary would fail). Instead we assert the
//! two structural invariants that jointly produce that guarantee:
//!
//!   1. `BenchHarnessBuilder.withProvider` takes exactly one
//!      parameter, and its parameter type is `GuardedProvider`
//!      (NOT `llm.Provider`). So any `llm.Provider` argument is a
//!      type mismatch, caught by the compiler.
//!
//!   2. `GuardedProvider` has no public constructor that accepts a
//!      raw `llm.Provider`. Only the typed factories (`forMock`,
//!      `forVcrReplay`) produce one, each bound to a concrete
//!      deterministic implementation.
//!
//! If either invariant is ever broken — by adding a `fromUnsafe`
//! factory, say — these tests fail and force a review.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const llm = tigerclaw.llm;
const bench_guards = tigerclaw.harness.bench_guards;

test "bench_guards: happy path — mock flows through the builder" {
    var mock = llm.MockProvider{ .replies = &.{} };
    const cfg = bench_guards.BenchHarnessBuilder.begin()
        .withSeed(123)
        .withProvider(bench_guards.GuardedProvider.forMock(&mock))
        .build();

    try testing.expectEqual(@as(u64, 123), cfg.seed);
    try testing.expectEqual(bench_guards.DeterminismSource.mock, cfg.provider.witness.source);
    try testing.expectEqualStrings("mock", cfg.provider.inner.name());
}

test "bench_guards: withProvider signature rejects unguarded providers" {
    // Structural check on the public surface. We assert by type that
    // `withProvider` takes a `GuardedProvider`, so attempting to pass
    // a raw `llm.Provider` is a compile-time type error at the call
    // site — which is the whole guard.
    const WithProviderFn = @TypeOf(bench_guards.BenchHarnessBuilder.withProvider);
    const info = @typeInfo(WithProviderFn).@"fn";
    try testing.expectEqual(@as(usize, 2), info.params.len); // self + provider

    const ProviderParamType = info.params[1].type.?;
    try testing.expect(ProviderParamType == bench_guards.GuardedProvider);

    // And, symmetrically, prove `GuardedProvider` is NOT identical to
    // `llm.Provider`. If somebody refactored them to the same type,
    // the guard would be meaningless.
    try testing.expect(bench_guards.GuardedProvider != llm.Provider);
}

test "bench_guards: GuardedProvider exposes only typed factories" {
    // Enumerate the declarations on `GuardedProvider` and assert the
    // only constructors are the deterministic ones. Any new public
    // `fromX` / `unsafe*` constructor added without updating this set
    // will fail the test and force a review.
    const decls = @typeInfo(bench_guards.GuardedProvider).@"struct".decls;
    const allowed = [_][]const u8{ "forMock", "forVcrReplay" };

    for (decls) |d| {
        // Skip fields and non-constructor utilities — we only flag
        // public functions that look like constructors ("for*" /
        // "from*" / "init" / "unsafe*").
        const is_constructor_like = std.mem.startsWith(u8, d.name, "for") or
            std.mem.startsWith(u8, d.name, "from") or
            std.mem.eql(u8, d.name, "init") or
            std.mem.startsWith(u8, d.name, "unsafe");
        if (!is_constructor_like) continue;

        var allowed_hit = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, d.name, a)) {
                allowed_hit = true;
                break;
            }
        }
        if (!allowed_hit) {
            std.debug.print("unexpected constructor on GuardedProvider: {s}\n", .{d.name});
            try testing.expect(false);
        }
    }
}

test "bench_guards: only the witness-bearing path reaches build()" {
    // `build()` is defined on `BuilderWithProvider`, not on
    // `BenchHarnessBuilder`. Assert this so a refactor that moves
    // build() up to the base builder (bypassing the provider
    // requirement) fails loudly.
    try testing.expect(!@hasDecl(bench_guards.BenchHarnessBuilder, "build"));
    try testing.expect(@hasDecl(bench_guards.BuilderWithProvider, "build"));
}

test "bench_guards: witness sources are the two approved variants" {
    // The enum exists so that approving a new determinism source is
    // a code change + review, not a silent boolean flip.
    const fields = @typeInfo(bench_guards.DeterminismSource).@"enum".fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("mock", fields[0].name);
    try testing.expectEqualStrings("vcr_replay", fields[1].name);
}
