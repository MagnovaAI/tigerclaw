# AGENTS.md

Authoritative engineering protocol for contributors and AI coding agents working on tigerclaw.

## Hard constraints

- Zig `0.16.0` exactly. Verify with `zig version` before building.
- Every commit compiles: `zig build` passes.
- Every commit ships tests for new testable code: `zig build test --summary all` passes with zero leaks.
- Every commit passes fmt: `zig fmt --check src/`.
- No TODO/FIXME without a referenced ADR or issue URL.

## Architecture

The plug architecture is specified in `docs/spec/agent-architecture-v3.yaml`. Read it before:

- adding a new capability or plugger
- adding a new plug under an existing plugger
- introducing a new verb (high bar — see §extension_points.new-verb)

The runtime state layout at `~/.tigerclaw/` is specified in `docs/spec/WORKING_DIR_TREE.yaml`.

### Key concepts

- **11 verbs:** identify, pair, sense, remember, reason, gate, act, converse, run, wake, attest
- **Pluggers** are capability slots (plural names): `providers`, `channels`, `memory`, `tools`, `guardrails`, `persona`, `pairing`, `supervisor`, `scheduler`, `auditor`, `clock`, `meter`, `telemetry`, `waiter`, `hook_bus`
- **Plugs** use singular prefix (`provider-anthropic`, `channel-discord`, `memory-sqlite`, `tool-github`, `guardrail-access-allowlist`, `persona-soul-md`)
- **Extensions** live under `extensions/<plug-id>/`; core primitives live at `src/` top level

### Vtable discipline

The runtime is vtable-driven. Subsystems expose a `ptr: *anyopaque` + `vtable: *const VTable` pair so that implementations are pluggable.

Every plugger vtable method takes `*const Context` as its first argument (`src/context.zig`). Methods return `PlugError!T` — never `anyerror!T` (`src/errors.zig`).

**Ownership rule:** callers must own the implementing struct (local var or heap allocation). Never return a vtable interface that points to a temporary — the pointer dangles.

Module initialization order lives in `src/root.zig`. Dependency direction flows inward toward primitives (log, clock, determinism, errors, capabilities). Subsystems must not import across each other.

### Versioning

CalVer, zero-padded: `YYYY.MM.DD` (e.g., `2026.04.23`). Never unpadded.

## Testing

- Unit tests live at the bottom of the file under test. Do not create a `tests/` directory for unit tests.
- `tests/` at the repo root holds integration, contract, e2e tests and fixtures only.
- Every vtable interface has a contract test suite reused across implementations.
- All tests use `std.testing.allocator` (leak-detecting). Every allocation has a matching `defer ... free(x)`.
- Tests must be deterministic. Inject clocks, fix seeds, isolate filesystem state with `std.testing.tmpDir(.{})`.
- Use `builtin.is_test` guards to skip side effects (network, process spawn, hardware).
- Test naming: `subject: expected behavior`.

## Conventions

- Conventional commit subjects (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`).
- Commit messages describe the engineering change. Do not reference tickets, tracker IDs, phases, or sequential numbering.
- Small, focused PRs. One reason to review.
- Files must end with a trailing newline.
