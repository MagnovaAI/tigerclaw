# ADR 0005: Config reload is signalled by a monotonic generation counter

**Status:** Accepted (v0.1.0)

## Context

Settings need to be reloadable without restarting the gateway. The
obvious candidates for "config changed" signalling were:

- A fingerprint hash of the loaded settings, compared on each read.
- An OS-level signal (`SIGHUP`) the boot layer listens for.
- A process-wide counter that a reload endpoint bumps, with consumers
  polling the value they last observed.

The counter variant is what
[`src/gateway/routes.zig`](../../src/gateway/routes.zig) exposes:

```zig
pub var reload_generation: std.atomic.Value(u64) = .init(0);
```

`POST /config/reload` calls `reload_generation.fetchAdd(1, .monotonic)`.
The endpoint returns immediately; the actual rebuild work lives in the
boot layer which watches the counter. Consumers that want to know "did
it change?" load the value, compare to the one they last saw, and
proceed — no global broadcast, no callback wiring.

A u64 atomic load is a single instruction on every architecture we
ship; a fingerprint hash would need a comparison loop and a lock
around the source of truth. The only consumer question is "is this
newer than what I saw?", and a counter answers that directly.

## Decision

The gateway keeps one process-wide `reload_generation: std.atomic.Value(u64)`.
`POST /config/reload` bumps it monotonically; anything that wants to
know about config changes compares the value it holds with a fresh
load.

The intended downstream behaviour is that the boot layer rebuilds an
immutable settings snapshot on each bump and atomic-swaps the pointer
in-flight handlers will observe on their next request. In-flight work
continues against the snapshot it already captured, so a reload
cannot tear a handler mid-request. In v0.1.0 the swap machinery is
not yet live — the counter is the contract, the swap consumer lands
with the real react-loop runner.

## Consequences

- A reload that fails validation leaves the previous snapshot in
  place. The operator sees a stderr log; the process keeps serving
  with the last-known-good config. There is no partial apply.
- The counter never decrements. Tooling that watches generation
  (`tigerclaw gateway status` in v0.2.0, external watchdogs today)
  can cache the last value cheaply and detect rollover only after
  `u64` overflow, which is not a real concern.
- The reload endpoint is cheap: a single atomic add. Operators
  scripting "reload after edit" workflows can call it freely; the
  cost is bounded.
- Because generation is monotonic and comparisons are `!=`, consumers
  do not need total ordering with other atomics. Observing a new
  generation is an eventually-visible hint, not a synchronisation
  point.
- A future multi-process or multi-host topology would need a
  different story — a local u64 does not round-trip across nodes.
  That is explicitly v0.2.0+ scope.
