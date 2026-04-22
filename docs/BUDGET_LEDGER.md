# Budget and cost ledger

Two cooperating layers bound what a session may spend:

1. **`harness.Budget`** — a per-session cap on turns, tokens, and cumulative cost. Checked at turn boundaries.
2. **`cost.Ledger`** — a shared, two-phase accountant for the same dollars, reconciled around every provider call.

The separation keeps the hot path cheap: `Budget` is read from one thread at safe points, while `Ledger` absorbs concurrent provider activity across threads. Together they give the runtime one answer to the question "may we spend more?" without any layer needing the other's state.

## Units

All cost is in integer **micro-USD** (10⁻⁶ USD). No floating-point accumulation anywhere — f64 sums would drift by addition order across threads, breaking replay determinism. See [ADR 0017](adr/0017_budget_ledger.md) for the unit choice.

Publishing prices are typically quoted per million tokens. `pricing.PricePerMillionMicros` is a `u64` of micro-USD per 1M tokens, so posting a $3.00 rate is literally `3_000_000`. The single rounding step happens in `pricing.costMicros(tokens, price)`, which ceils so the ledger runs a fraction ahead of the provider's actual billing.

## Budget

[`harness.Budget`](../src/harness/budget.zig) is four atomic counters behind per-axis limits:

| Axis             | Incremented by              | Tripped when          |
|------------------|-----------------------------|-----------------------|
| `turns`          | one per user→assistant pair | `turns >= limit`      |
| `input_tokens`   | prompt tokens               | `input >= limit`      |
| `output_tokens`  | completion tokens           | `output >= limit`     |
| `cost_micros`    | priced micro-USD            | `cost >= limit`       |

`Limits` value of `0` disables that axis. `Budget.exceeded()` returns the first tripped axis in declaration order, so the caller can explain precisely which cap halted the session.

Atomic counters allow streaming token billers (e.g. an SSE reader counting output tokens as chunks arrive) to accumulate without locking.

## Ledger

[`cost.Ledger`](../src/cost/ledger.zig) is a two-phase accountant shared across the whole session:

```
reserve(upper_bound) → Reservation
commit(res, actual) | release(res)
```

The two phases solve one concrete problem: two concurrent provider calls must not both decide they have budget when they would together overshoot. `reserve` atomically checks `spent + pending + upper_bound <= ceiling`; if it fits, it bumps `pending`. Only a later `commit` moves the reservation into `spent`; `release` returns it unconsumed.

`spent + pending` is the canonical committed amount. Never compare `spent` alone against the ceiling — that is the race the two-phase protocol exists to prevent.

Handles are plain values. `Reservation{id, amount_micros}` has no destructor of its own; the harness wrapper [`shared_ledger.Held`](../src/harness/shared_ledger.zig) layers a `defer held.deinit()` ergonomic that auto-releases if the caller never commits.

### Usage pricing

[`usage_pricing.priceUsage`](../src/cost/usage_pricing.zig) converts a `types.TokenUsage` into a bucketed micro-USD result. Cache rates fall back to the input rate when unset (matching every provider we have seen). Unknown models produce zero cost and set `Priced.unknown_model`, so operators can notice missing table entries before they are billed by surprise.

`Ledger.commitUsage` is the one-call convenience: price the usage, clamp to the reservation, and commit. When the priced cost exceeds the reservation, the excess is recorded via `recordDirect` so the ledger stays balanced without inflating a reservation after the fact.

### Reporter

[`cost.Reporter`](../src/cost/reporter.zig) aggregates per-model totals separately from the ledger. `snapshot()` emits a descending-cost list with ties broken on model name, so a CI log is deterministic under replay.

## Wiring

A provider call looks like:

```zig
var held = try shared_ledger.reserve(upper_bound_micros);
defer held.deinit();                          // auto-release on early return

const response = try provider.chat(...);       // may fail

const priced = try reporter.recordUsage(
    pricing_table, model, response.usage,
);
try held.commit(priced.cost_micros);          // settles reservation

harness_budget.recordTurn(                     // updates per-session cap
    response.usage.input,
    response.usage.output,
    priced.cost_micros,
);
if (harness_budget.isExhausted()) { /* halt */ }
```

Nothing in that sequence allocates more than the reservation map entry; the hot path is lock-free on `Budget` and holds the ledger's spinlock only long enough to mutate the three relevant fields.

## Files

- [`src/harness/budget.zig`](../src/harness/budget.zig) — per-session caps and atomic counters.
- [`src/harness/shared_ledger.zig`](../src/harness/shared_ledger.zig) — RAII-style reservation handle.
- [`src/cost/pricing.zig`](../src/cost/pricing.zig) — model prices, micro-USD arithmetic.
- [`src/cost/usage_pricing.zig`](../src/cost/usage_pricing.zig) — `TokenUsage` → `Priced`.
- [`src/cost/ledger.zig`](../src/cost/ledger.zig) — thread-safe two-phase ledger.
- [`src/cost/reporter.zig`](../src/cost/reporter.zig) — per-model aggregation.
