# Architecture

tigerclaw is an agent runtime written in Zig. This document describes the high-level module layout that the codebase is growing into. It is intentionally a stub — new subsystems extend it in the same commit that lands them.

## Dependency direction

The runtime is organised as concentric layers. Dependencies flow inward; outer layers depend on inner ones, but never the reverse. Subsystems at the same layer do not import across each other.

```
                       core primitives
              (log, clock, determinism, errors, version)
                              │
                              ▼
                        types + settings + constants
                              │
                              ▼
                        trace + VCR
                              │
                              ▼
                 LLM stack (providers, transport,
                            routing, reliability)
                              │
                              ▼
                 harness (session, budget, mode,
                          sandbox, permissions, cost)
                              │
                              ▼
                   entrypoints, agent loop, tools
                              │
                              ▼
                  scenarios, bench, eval, e2e
```

## Vtable contract

Every pluggable subsystem exposes a `ptr: *anyopaque` plus a `vtable: *const VTable`. Implementations are local structs that synthesize the interface with a small `fn thing(self: *Impl) Interface` method.

Ownership rule: callers own the implementing struct. Never return an interface that points to a temporary — the pointer will dangle.

## Tests

Unit tests live at the bottom of the file under test. Integration, contract, and end-to-end tests live in `tests/` at the repo root. See [../tests/README.md](../tests/README.md) and `AGENTS.md`.

## Further reading

- [DETERMINISM.md](DETERMINISM.md)
- [adr/](adr/) — decision records
