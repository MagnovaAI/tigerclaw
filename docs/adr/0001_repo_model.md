# ADR 0001 — Repo model

**Status:** Accepted.

## Context

The runtime needs a repository layout that can grow from a bare skeleton into a multi-subsystem codebase without mid-stream reorganisation. Two broad shapes were considered: a monorepo with `packages/<name>/` workspace members, and a single-root tree with subsystems living as directories inside `src/`.

## Decision

Use a single-root Zig package. All runtime code lives under `src/`, grouped by subsystem (`src/trace/`, `src/harness/`, `src/llm/`, ...). Integration tests live at `tests/` at the repo root. Out-of-tree plugins will live in a sibling `extensions/` directory when they land.

Top-level primitives (`log`, `clock`, `determinism`, `errors`, `version`, `globals`, `cli`, `main`, `root`) stay at `src/` root; everything else is a subdirectory.

## Alternatives considered

- **Workspace monorepo (`packages/core/`, `packages/harness/`, ...):** over-engineered for a single-binary runtime. Adds per-package manifests, cross-package build plumbing, and cognitive overhead with no payoff until multiple published artifacts exist.
- **Flat `src/` with everything at the top level:** fast early on, but stops scaling the moment three subsystems want files named `types.zig` or `root.zig`.

## Consequences

- Subsystems are directories; each subsystem has a `root.zig` that re-exports its public surface.
- The library surface is assembled in `src/root.zig`, which `main.zig` pulls in for `refAllDecls` in tests.
- Integration tests register explicitly in `build.zig` (see ADR 0002 on harness scope for the reason that matters).
