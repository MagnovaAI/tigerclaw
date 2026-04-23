# CLAUDE.md

Guidance for Claude Code (and other AI agents) working in this repository.

**Read `AGENTS.md` before any code change.** It is the authoritative engineering protocol. It links to the plug architecture spec at `docs/spec/agent-architecture-v3.yaml` and the runtime state layout at `docs/spec/WORKING_DIR_TREE.yaml` — read those when touching anything plug-shaped.

## Build & test

```sh
zig version                         # must be 0.16.0
zig build                           # dev build
zig build test --summary all        # full test suite, must pass with 0 leaks
zig fmt src/                        # format
zig fmt --check src/                # verify formatting
```

Run a single test file during development:

```sh
zig test path/to/file.zig
```

## Where tests live

- Unit tests: at the bottom of the file under test, inside `test "name" {}` blocks.
- Integration / contract / e2e: `tests/*_test.zig`.
- Fixtures: `tests/fixture_*.{json,yaml,jsonl}` and `@embedFile` where appropriate.

Do not create ad-hoc `tests/` directories inside `src/`.

## Commit discipline

- Conventional commit subjects.
- Describe the change itself. No tracker references, no sequential numbering, no orchestration metadata.
- Each commit must compile and pass tests.
