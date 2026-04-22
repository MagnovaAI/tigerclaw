# Mode policy

The runtime operates in exactly one of four mutually exclusive modes for the lifetime of a session. The mode is picked at startup — either from `Settings.mode` or a CLI flag — and is **pinned** thereafter. Attempting to switch mid-session raises `error.ModePinned`.

| Mode     | Purpose                                            | Live network | Wall clock | Filesystem writes | Subprocess spawn |
|----------|----------------------------------------------------|--------------|------------|-------------------|------------------|
| `run`    | Normal interactive/automated use.                  | yes          | yes        | yes               | yes              |
| `bench`  | Benchmarking. Reproducible inputs, fixed clocks.   | no           | no         | yes (for output)  | no               |
| `replay` | Replay a recorded trace / VCR cassette.            | no           | no         | no                | no               |
| `eval`   | Evaluation harness. Same determinism as `bench`.   | no           | no         | yes               | no               |

The table is the authoritative source of truth — it is what [`src/harness/mode_policy.zig::Capabilities.of`](../src/harness/mode_policy.zig) returns. If a new subsystem is about to perform a side effect, it asks the mode policy first:

```zig
try harness.mode_policy.Policy.init(mode).require(&.{ .run });
```

A `require` miss returns `error.ModeNotAllowed` and the call site must refuse the action.

## Why a pinned mode

A session that silently flips from `bench` to `run` would invalidate the replay guarantees all of `trace/` and `vcr/` depend on. The pin is a belt-and-braces check the harness offers to every other subsystem: "you cannot accidentally be in a mode that breaks my assumptions."

The `Policy.transition` API exists only so that `mode` can be set-once on construction. A transition to the same mode is a no-op; any other transition returns `error.ModePinned`.

## Bench guards

`bench` and `eval` forbid live providers because response latency, retry jitter, and nondeterministic sampling would pollute measurements. We enforce that **at compile time** using nominal typing — see [ADR 0012](adr/0012_bench_guards.md) for the rationale.

Shape:

- [`bench_guards.GuardedProvider`](../src/harness/bench_guards.zig) is a nominal wrapper whose only constructors (`forMock`, `forVcrReplay`) accept concrete deterministic provider types.
- [`bench_guards.BenchHarnessBuilder`](../src/harness/bench_guards.zig) has a single `withProvider` method typed to `GuardedProvider`. Passing a raw `llm.Provider` is a type mismatch at the call site.
- There is no `fromUnsafe` escape hatch. Adding one would require editing `bench_guards.zig` — the review checkpoint is the feature.
- `build()` is defined on the intermediate `BuilderWithProvider` type, so `begin().build()` (without a provider) is a compile error too.

The guardrail extends via adding a variant to `DeterminismSource` plus a dedicated `for<X>` factory. Each new variant is a reviewed change that names the concrete replay-safe type it is accepting.

## Relation to other subsystems

- **Sandbox** ([`src/sandbox/`](../src/sandbox/)) applies a policy layer on top of capabilities. Capabilities answer "is X allowed for this mode at all?"; the sandbox policy refines that to "which specific resources are allowed?".
- **Permissions** ([`src/permissions/`](../src/permissions/)) layers user consent on top of both. A `run` session can still ask the user before `fs_write`.
- **Trace** ([`src/trace/`](../src/trace/)) tags every envelope with the mode it was recorded under; replay refuses to feed a `run`-mode trace into `replay` mode and vice versa.
