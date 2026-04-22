# Determinism

A run of tigerclaw is **deterministic** when rerunning the same scenario on the same code, with the same inputs and the same seeds, produces byte-identical traces.

Determinism is what makes replay, bench, and eval trustworthy. It also makes bugs reproducible. Every primitive that can introduce non-determinism has an explicit knob.

## Sources of non-determinism and their knobs

| Source | Knob |
|---|---|
| Wall-clock time | `clock.Clock` vtable. Tests use `FixedClock` or `ManualClock`; production wires a `CallbackClock` over the runtime time source. |
| Randomness | `determinism.Rng`. Tests call `Rng.initSeeded(determinism.fixed_seed)`; production calls `Rng.initFromOs`. |
| Iteration order | Never iterate over a `HashMap` in serialized output. Sort by key or use an ordered container. |
| Thread interleaving | Work that touches shared state serializes through a single owner. Threaded parallelism lives behind explicit primitives. |
| External services | Replayed from VCR cassettes (once the VCR subsystem lands). Live calls are tagged and gated by a `TIGERCLAW_LIVE` env var. |
| Allocator behaviour | Tests use `std.testing.allocator` so leaks fail loudly, but allocation order must not leak into output. |

## Rules

- A subsystem that needs a clock takes a `Clock` by value.
- A subsystem that needs randomness takes a `*std.Random` (obtained from `Rng.random()`).
- A subsystem that needs IDs takes a `*std.Random` or a seeded generator. Never `@intFromPtr` or `std.time.*` directly.
- Iteration over unordered containers in user-visible output is a bug.

## See also

- [adr/0006_determinism_model.md](adr/0006_determinism_model.md)
