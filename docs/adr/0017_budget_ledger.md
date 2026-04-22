# ADR 0017 — Budget and cost ledger

**Status:** Accepted.

## Context

Every session runs against some spending limit. The limit is usually a number the operator types into settings: "this agent may burn $5 before it stops". Enforcing that reliably is harder than it looks:

- **Races.** Two concurrent provider calls both read `spent = X`, both decide the ceiling is not yet reached, both fire, and together overshoot.
- **Drift.** Accumulating costs in `f64` sums to a different total depending on thread interleaving. Replay becomes irreproducible.
- **Leakage.** A call that fails between "reserve budget" and "record cost" must not permanently lock the money.
- **Granularity.** The answer to "may we spend more?" gets asked in two different places: at turn boundaries (by the harness) and around provider calls (by the client). Those read patterns do not want the same lock.

## Decision

Two cooperating layers, integer-only arithmetic.

### Integer micro-USD everywhere

All cost values are `u64` in micro-USD (10⁻⁶ USD). One rounding step, in `pricing.costMicros(tokens, price)`, ceils to keep accounting a fraction ahead of the provider's billing. No f64 anywhere in the aggregation path.

Publishing prices are quoted per million tokens. We store `PricePerMillionMicros = u64` so a $3.00 rate is literally `3_000_000` — the operator pastes the posted rate, scaled by 10⁶, into settings.

### `harness.Budget` — per-session caps

Four atomic `u64` counters: `turns`, `input_tokens`, `output_tokens`, `cost_micros`. Each has an optional limit (`0` disables the axis). `Budget.exceeded()` returns the first tripped axis in declaration order. `recordTurn` uses `fetchAdd`, so a streaming token biller can attribute chunks without taking any lock.

Budget is read at *safe points* the harness chooses (end of a turn, between tool iterations). The per-axis "stale snapshot" concern is bounded by a single writer's delta, which is fine for enforcement because counts are monotonic — a missed tick only means the limit trips on the next check, not later than that.

### `cost.Ledger` — two-phase shared accountant

Single shared ledger per session, with a reserve/commit/release protocol:

```
reserve(upper_bound) → Reservation          // pending += upper_bound, atomically
commit(res, actual)                          // pending -= upper_bound; spent += actual
release(res)                                 // pending -= upper_bound
```

The ceiling check is `spent + pending + upper_bound <= ceiling`, evaluated under the lock. Two concurrent `reserve` calls against a tight ceiling cannot both succeed — the test `parallel reserves respect the ceiling` confirms exactly `floor(ceiling / chunk)` reservations win a race of 32 threads.

Reservations are plain values; the ergonomic wrapper `harness.shared_ledger.Held` layers a `defer held.deinit()` auto-release so the "call failed after reserve, before commit" case cannot leak headroom. A double-commit raises `UnknownReservation`, which surfaces bugs loudly instead of quietly corrupting the ledger.

### Lock choice

Zig 0.16 does not ship `std.Thread.Mutex`; `std.Io.Mutex` requires threading an `Io` handle through every call site. Rather than contaminating every ledger caller with `Io`, the ledger uses a tiny `std.atomic.Value(bool)` spinlock with a `Thread.yield` in the contention path. The critical section is a handful of struct writes, so the lock cost is a couple of hundred cycles on uncontested access.

The budget uses plain atomics because its operations are single-field increments; no coherent multi-field snapshot is needed.

## Rules

1. **No float aggregation.** Costs accumulate in `u64`; rounding happens once in `pricing.costMicros`.
2. **Never compare `spent` alone against `ceiling`.** The comparison is always against `spent + pending`. This is the invariant the two-phase protocol buys.
3. **Every reservation settles.** Commit, release, or `deinit` refund. `Held.deinit` swallows release errors (they cannot reach the caller anyway) after logging them via `std.log`, so forgotten-settlement bugs still surface in structured log output.
4. **Over-commit clamps.** `Ledger.commitUsage` clamps the actual cost to the reservation and records the excess via `recordDirect`. That keeps the ledger honest without requiring reservations to predict the future precisely.

## Alternatives considered

- **Single lock, no reservations.** Simpler code, but the race is unfixable without knowing what a call will cost before it returns.
- **f64 cost accumulation.** Matches the dollar-denominated feel operators expect, but sums to different totals across thread orders. Kills replay.
- **`std.Io.Mutex` for the ledger.** Correct and library-blessed, but every caller of `Ledger.reserve` would take an `Io` parameter. That parameter would then flood outward through every subsystem that touches the ledger.
- **One `BudgetLedger` merging the two layers.** Couples the hot atomic path to the colder reservation path; either atomics or locks end up doing double duty.

## Consequences

- `harness.budget.Limits` and the ledger ceiling are independent by design. An operator configures both; they do not derive one from the other, because the budget axes (tokens, turns) are not interchangeable with the dollar axis.
- `Reporter` aggregates per-model totals separately from the ledger, keeping the hot path cheap and the aggregation logic evolvable without touching ledger internals.
- Future persistence ("how much did this user spend last month") attaches to the reporter, not the ledger. Reporter lookup is by model, snapshot is sorted deterministically, and the JSON form is already implied by the struct layout — all three properties the persistence step will want.
