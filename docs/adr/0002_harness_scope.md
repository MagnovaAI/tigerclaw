# ADR 0002 — Harness scope

**Status:** Accepted.

## Context

"Harness" is an overloaded word. It could mean a test runner, an agent loop supervisor, a benchmarking framework, or all three at once. The runtime needs a single, agreed definition so that the word carries weight in commit messages and file paths.

## Decision

In tigerclaw, the **harness** is the object that owns a run. It:

1. Starts and ends a session.
2. Holds the budget, the permissions, the sandbox policy, and the mode (`run | bench | replay | eval`).
3. Drives the turn loop — calling the provider, dispatching tools, recording into the trace.
4. Enforces invariants (mode forbidden ops, bench guards, cost ledger debits).
5. Is re-entrant under `--resume <session_id>`; no separate resume entrypoint.

The harness does **not**:

- Implement tool behaviour (tools live in `src/tools/`).
- Implement provider protocols (providers live in `src/llm/providers/`).
- Schedule bench runs (bench lives in `src/bench/`, built on top of the harness).
- Load scenarios (scenarios live in `src/scenario/`).

## Alternatives considered

- **Harness as a test fixture only:** conflates harness with `std.testing` and leaves the agent loop without a clear owner.
- **Harness as the full runtime entrypoint:** overlaps with `src/entrypoints/*.zig`, which should stay thin arg-parsers that hand off to the harness.

## Consequences

- Mode policy and bench guards live in `src/harness/mode_policy.zig` and `src/harness/bench_guards.zig`.
- The cost ledger's caller-facing wrapper (`shared_ledger.zig`) lives in `src/harness/` because the harness is its primary consumer.
- Entrypoints construct a harness and hand it back a configured `Session`; they never reach into its internals.
