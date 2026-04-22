# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once the first tagged release lands.

## [0.1.0-alpha] — first tagged cut

The initial alpha covers an end-to-end agent runtime: session lifecycle, provider layer, tool registry, context engine, bench and eval subsystems, and the policy plumbing that keeps replay deterministic.

### Added

- **Primitives.** Canonical domain types (`Message`, `ToolCall`, `ToolResult`, `TokenUsage`, `ModelRef`, `LlmResponse`), constants module, log, clock, determinism seed, errors taxonomy.
- **Settings.** Layered configuration: defaults → file → env → MDM → runtime patches, with atomic writes and change detection.
- **Trace v2.** Streaming JSONL trace, recorder/replayer/diff, redaction, tool-use summary, hash-envelope per ADR 0009.
- **VCR cassettes.** HTTP record/replay with cassette integration tests.
- **LLM stack.** Provider vtable, client facade, token estimator, mock + Anthropic + OpenAI + Bedrock providers, SSE parser, routing, reliability (retry/rate limit/breaker) and fault injection.
- **Harness.** Session persistence (`--resume`), per-session `Budget`, cooperative `Interrupt`, respawn controller, typed bench guards, pinned `Mode` policy, shared ledger wrapper.
- **Cost.** Two-phase `Ledger` (reserve/commit/release) with micro-USD integer arithmetic, pricing + usage_pricing + reporter.
- **Sandbox.** Policy + fs/exec/net checks + detect (Noop today; Linux/Docker slots behind the same vtable).
- **Permissions.** `AutonomyLevel` + per-kind `Mode` + approval `Store` + `Responder` vtable facade.
- **Agent.** React loop, `ToolExecutor` vtable, prompt builder, prompt-cache planner, tool-selection filter, trajectory log, context engine (window/compaction/references/hints/feedback).
- **Tools.** Registry + batch-1 (`read`, `write`, `edit`, `grep`, `glob`), batch-2 (`bash`, `apply_patch`, `task_delegate`, `ask_user`, `todo_write`), shim tools (`clock_now`, `gen_id`, `random_seeded`, `check_mode`, `cost_check`, `token_count`), justification lint.
- **Scenario v3.** JSON loader + three toy scenarios (`coding_refactor_rename`, `nav_read_and_summarize`, `data_sql_debug`).
- **Bench.** Runner, scheduler (parallel with deterministic ordering), metrics, aggregator, reporter, compare, SHA-256 hash guard.
- **Eval.** Dataset, golden, bless, report, assertion with witness invariants (≤16 per run, pass-with-witness rejected at construction), rubric + heuristic judge.
- **Entry points.** `run`, `doctor`, `list` with a shared injected-IO shape.
- **Documentation.** `ARCHITECTURE.md`, `DETERMINISM.md`, `SETTINGS.md`, `TRACE_FORMAT.md`, `VCR_FORMAT.md`, `BENCH_INVARIANTS.md`, `MODE_POLICY.md`, `BUDGET_LEDGER.md`. ADRs 0001 through 0022 covering the repo model, harness scope, trace format, determinism, settings layering, bench invariants, bench guards, budget/ledger, and the error taxonomy.
- **CI gates.** `ci_check_tool_justification.sh`, `ci_check_witness_cardinality.sh`, `ci_check_assertion_freeze.sh`, `ci_check_mode_enum.sh`.
- **End-to-end tests.** `e2e_run_with_mock_test`, `e2e_replay_roundtrip_test`, `e2e_bench_full_run_test`, `e2e_eval_full_cycle_test`.

### Invariants

- Every commit compiles (`zig build`).
- Every commit passes the full suite with zero leaks (`zig build test --summary all`).
- `zig fmt --check src/ tests/` passes.
- Witness cardinality cap (16/run) and assertion validate() invariants are CI-gated.
