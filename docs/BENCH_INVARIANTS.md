# Bench invariants

A bench run compares two traces and claims one is better. The claim is only worth the reader's trust if the inputs that could have moved are all pinned.

tigerclaw commits to **four hashes**, carried in every trace envelope:

| Slot | What it commits to |
|---|---|
| `dataset_hash`  | the scenario inputs the harness ran against |
| `golden_hash`   | the expected outputs used to pass/fail |
| `rubric_hash`   | the judge's scoring rules (empty if no judge) |
| `mutation_hash` | setup mutations applied to the harness (seeds, overlays) |

Every bench compare re-computes the hashes from its on-disk inputs and cross-checks them against the envelope. A mismatch is refusal, not a warning.

## Rules

1. `trace.schema.checkVersion` runs before anything else.
2. Any hash difference between the two traces blocks the comparison.
3. "Empty" (`Digest.isSet() == false`) is a legal value that means "not pinned." Comparing an empty slot against a populated one is still a mismatch — they are not equivalent.
4. The envelope's hashes are a commitment. The authority is the on-disk input + the bench recomputation.

## Rationale

- Without `dataset_hash`, a scenario rewrite silently becomes a regression.
- Without `golden_hash`, a golden rebless silently becomes a "win."
- Without `rubric_hash`, a judge tweak silently moves the baseline.
- Without `mutation_hash`, a different seed silently inflates variance.

## See also

- [adr/0009_bench_invariants.md](adr/0009_bench_invariants.md)
- [TRACE_FORMAT.md](TRACE_FORMAT.md)
