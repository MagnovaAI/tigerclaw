# ADR 0022 — Error taxonomy

**Status:** Accepted.

## Context

Zig errors are distinct error-set identifiers. Every module could invent its own set, but that makes downstream classification impossible: retry policy, circuit breakers, and tool-result payloads all need a stable vocabulary for "this kind of failure."

We need one canonical list — small enough to memorise, large enough to drive routing decisions.

## Decision

`src/errors.zig` defines a single `Id` enum. Every public failure mode across the runtime maps onto exactly one variant. The taxonomy covers:

- **Core primitives:** `invalid_argument`, `not_found`, `permission_denied`, `timed_out`, `cancelled`, `unavailable`.
- **I/O:** `io_read`, `io_write`, `io_closed`.
- **Parse / schema:** `parse_failure`, `schema_mismatch`, `version_mismatch`.
- **Budget / rate:** `budget_exhausted`, `rate_limited`.
- **Harness:** `mode_forbidden`, `interrupt_requested`.

String forms live in `src/constants/error_ids.zig` so trace writers and tool-result encoders can reference the name without depending on the enum type. A compile-time test in `error_ids.zig` mirrors the enum field-by-field — a rename or reorder fails CI immediately.

## Rules

1. **Appending is a minor change.** Adding a new variant is non-breaking as long as no existing code uses `.Exhaustive` on a switch over `Id` without an `else` branch.
2. **Renaming is a breaking change.** Bump the module version, update the stability trip-wire test, and add a CHANGELOG entry.
3. **Retiring is a two-step dance.** Mark the variant deprecated in the description table but leave the slot in place; delete only after a major version bump.
4. **Module-specific detail lives in the error slice, not in a new `Id`.** If the detail is worth branching on, lift it to the taxonomy instead of carrying a freeform string.

## Alternatives considered

- **Freeform string ids.** Easy to write; impossible to switch on. Retry policy can't ask "is this retryable?" without string parsing.
- **Per-subsystem error sets with no central taxonomy.** Works locally; fails at the boundaries where tools, traces, and budgets need to classify.

## Consequences

- Tools return `ToolResult{ outcome: .err: { id, detail } }` where `id` is one of the canonical strings.
- Reliability policies switch on `Id` to decide `retry | give_up | circuit_open`.
- Provider adapters translate vendor error payloads into the taxonomy at the boundary.
- The taxonomy stays small on purpose. When you reach for a new variant, check whether an existing one plus a detail string covers the case first.
