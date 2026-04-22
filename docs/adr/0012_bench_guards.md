# ADR 0012 — Bench guards: compile-time provider safety

**Status:** Accepted.

## Context

Benchmarks and evaluations compare runs against each other. A run whose provider responses depend on live network latency, retry jitter, or backend-side sampling is not comparable to any other run — not even to itself. Historically, "please don't use a live provider here" has been a comment in a readme and a runtime check on the `Mode` enum. Both are defeatable: a contributor adding a new bench harness who does not know the comment is there will silently break every measurement thereafter.

## Decision

The bench harness accepts providers only through a nominal wrapper, `bench_guards.GuardedProvider`, whose only constructors require proof of determinism. The proof takes the form of an enum variant in `DeterminismSource` plus a typed factory function that accepts only the concrete deterministic provider type.

Concretely:

- `BenchHarnessBuilder.withProvider(provider: GuardedProvider)` — the parameter type is `GuardedProvider`, not `llm.Provider`. Passing a raw `llm.Provider` yields `error: expected type 'harness.bench_guards.GuardedProvider', found 'llm.provider.Provider'` at the call site.
- `GuardedProvider.forMock(*llm.MockProvider)` — only accepts the mock.
- `GuardedProvider.forVcrReplay(*VcrProvider)` — only accepts the VCR-backed provider.
- No `fromUnsafe`, no `fromProvider`, no `anytype` bypass.
- `build()` is defined on `BuilderWithProvider`, a distinct intermediate type, so `begin().build()` (no provider) is also a compile error.

A compile-fail test harness captures the negative case outside the test binary (running it inside would fail the whole suite). The positive tests assert structural invariants via `@typeInfo` so a refactor that changes the withProvider parameter type, or adds a new constructor to `GuardedProvider`, has to update this test — the review checkpoint is the whole feature.

## Rules

1. **Adding a deterministic provider class** requires a new variant in `DeterminismSource` *and* a dedicated `for<X>` factory accepting only the concrete type. The enum gate is the review hook.
2. **No runtime escape hatch.** A setting or env var that promotes a live provider to bench-safe would defeat the guarantee. If an operator wants to use a live provider under bench mode, they are asking for meaningless numbers; that request belongs in a bug, not a flag.
3. **The wrapper is zero cost.** `GuardedProvider` is a POD struct over the underlying vtable pointer plus the witness tag. The guarantee is nominal typing, not runtime enforcement.

## Alternatives considered

- **Runtime check on `Mode`.** A provider passed in bench mode could assert at init. This fails the contributor's-new-bench scenario: the failure is a test flake, not a compile error. Too late.
- **Hand-roll a `BenchProvider` interface separate from `llm.Provider`.** Forks the provider vtable — every real provider grows a duplicate path. Doubles the maintenance surface without buying anything over a wrapper type.
- **Trust the `Settings.mode = .bench` predicate.** The whole problem is that we do not want to rely on a flag that an operator can flip. A type error is harder to defeat than a boolean.

## Consequences

- Test infrastructure can introspect `GuardedProvider.decls` to assert no new escape-hatch constructor slipped in. Used by `tests/bench_guards_test.zig`.
- When the real VCR-backed replay provider lands (later in the roadmap), we extend the `VcrProvider` stub in `bench_guards.zig` in place. Every bench caller picks up the new implementation for free.
- The bench guards are a template for other compile-time safety affordances the roadmap needs (judge witnesses, golden-file gates). The pattern — nominal wrapper, enum-gated constructors, absence of a `fromUnsafe` — reappears.
