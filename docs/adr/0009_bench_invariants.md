# ADR 0009 — Bench invariants

**Status:** Accepted.

## Context

Benchmarks are the one place where "it looked roughly right" is not acceptable. A bench compares two runs on a set of inputs and makes a claim about which is better. That claim has to survive the next year of code churn, so the comparison must hinge on something the reader can verify.

## Decision

Every trace envelope carries four hash slots: `dataset_hash`, `golden_hash`, `rubric_hash`, `mutation_hash`. All four travel inside the header (`trace.schema.Envelope`), per ADR 0003. The bench subsystem (landing later) refuses to compare two traces whose hash tuples disagree.

The hashes pin exactly what the reader needs to know was held constant:

- **`dataset_hash`** — the input scenario set.
- **`golden_hash`** — the expected outputs used for pass/fail.
- **`rubric_hash`** — the judge's scoring rules, if judging is active.
- **`mutation_hash`** — the set of setup mutations applied to the harness (seeds, patch overlays).

Empty (`Digest.isSet() == false`) is a legal value: it means "nothing of this kind was pinned for this run." Comparing a run where `rubric_hash` was unset against one where it was set is itself a hash mismatch and is rejected.

## Rules

1. **No compare across version mismatches.** `trace.schema.checkVersion` runs first.
2. **No compare across hash mismatches.** Bench compare emits a diagnostic and refuses to score.
3. **Hashes are computed on ingest.** The bench reader recomputes them from the on-disk inputs and cross-checks against the envelope — the envelope's hashes are a commitment, not an authority.
4. **Hashes are opaque hex.** `Digest.hex` is a `[]const u8`; the bench layer interprets, the trace layer just stores.

## Alternatives considered

- **Hash the whole trace file.** Changes every run because of timings. Tells you nothing about which input moved.
- **Hash only the dataset.** Misses golden/rubric drift, which is where the quiet bugs hide.
- **No hashes, require identical git SHAs.** Works for local checkouts, but sidesteps the "what is actually being compared" question and breaks for rehydrated fixtures.

## Consequences

- The trace envelope must keep all four slots forever; a slot is retired by marking it unused in a new schema_version and migrating callers.
- Bench compare is deliberately strict. Tooling will exist to relax this when appropriate (e.g., `--ignore-rubric`), but the default is to refuse.
- Any later subsystem that wants to be replay-stable (calibration, eval, regression feeder) re-uses this invariant rather than inventing its own.
