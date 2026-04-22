# docs/

Entry point for project documentation. Documents are added as the subsystems they describe land — this index stays short on purpose.

## Current documents

- [ARCHITECTURE.md](ARCHITECTURE.md) — high-level module layout and dependency rules.
- [DETERMINISM.md](DETERMINISM.md) — what "deterministic" means here, and which knobs enforce it.
- [SETTINGS.md](SETTINGS.md) — layered configuration: defaults → file → env → MDM → runtime patches.

## Architecture decision records

ADRs live under [`adr/`](adr/) and are numbered as they are accepted. An ADR captures a decision, the forces that shaped it, and the alternatives considered. Supersedes are linked explicitly.

- [0001 — Repo model](adr/0001_repo_model.md)
- [0002 — Harness scope](adr/0002_harness_scope.md)
- [0006 — Determinism model](adr/0006_determinism_model.md)
- [0007 — Settings layering](adr/0007_settings_layering.md)
- [0022 — Error taxonomy](adr/0022_error_taxonomy.md)

## Conventions

- Markdown, one sentence per line where it helps review diffs.
- Link sibling docs with relative paths.
- Do not reference external trackers, ticket IDs, or sequential commit numbering in docs. Describe the thing, not the workflow that produced it.
