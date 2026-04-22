# ADR 0006 — Determinism model

**Status:** Accepted.

## Context

Replay, bench, and eval all rely on the runtime producing byte-identical traces for the same inputs. A "best-effort" determinism policy is worth nothing — the moment a diff is ambiguous, trust in the tooling evaporates. See [../DETERMINISM.md](../DETERMINISM.md) for the user-facing summary.

## Decision

Determinism is enforced primitive-by-primitive, not by an outer sandbox:

1. **Clock is a vtable.** Code that needs time takes a `Clock` by value. No direct `std.time.*` calls in runtime code.
2. **Randomness is seeded.** The `Rng` struct has `initSeeded(Seed)` and `initFromOs()`. Anything RNG-dependent takes a `*std.Random`.
3. **IDs are RNG-derived.** When the util subsystem lands, `util/id.zig` will take a `*std.Random` — never `@intFromPtr` or timestamps.
4. **Iteration order is explicit.** Iterating a `HashMap` into user-visible output is a bug. Use an ordered container or sort by key.
5. **External I/O is replayable.** Network traffic records to / replays from VCR cassettes; live calls are explicitly tagged and gated.

## Alternatives considered

- **"Try to be deterministic" (no hard primitives):** fails on the first dependency that quietly reaches for `std.time`. Produces traces that diff for reasons no one can explain.
- **Docker sandbox with a frozen clock:** works for end-to-end tests but doesn't help the agent loop, unit tests, or bench runs.

## Consequences

- The wall-clock `RealClock` is **deferred** until the I/O subsystem lands. Until then, entry points pass a `CallbackClock` over whatever time source they have. Tests never touch wall time.
- Every test that could race the clock uses `ManualClock` or `FixedClock`.
- A trace with a non-deterministic field — a timestamp, a hash-map iteration order, an unseeded draw — is a bug against this ADR.
