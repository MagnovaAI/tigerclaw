# Configuration

The runtime resolves settings from three layers, applied in order:

1. **Built-in defaults** — pinned in `src/constants/defaults.zig`.
2. **`settings.json`** — JSON file in the data directory; partial files
   are allowed (missing fields fall back to defaults).
3. **Environment overrides** — `TIGERCLAW_*` vars; applied last so they
   always win.

The schema is defined in `src/settings/schema.zig`; this document
mirrors it. If the two disagree, the source wins.

## Data directory

The runtime resolves its data directory in this order:

| Var                  | Path used                         | When                              |
|----------------------|-----------------------------------|-----------------------------------|
| `TIGERCLAW_HOME`     | `$TIGERCLAW_HOME`                 | When set                          |
| `XDG_CONFIG_HOME`    | `$XDG_CONFIG_HOME/tigerclaw`      | When `TIGERCLAW_HOME` is unset    |
| `HOME`               | `$HOME/.tigerclaw`                | Fallback                          |

The same directory holds:

- `settings.json` — user settings.
- `outbox/<channel>.jsonl` — durable outbound queue.
- `sessions/<id>.json` — session state (when wired in v0.2.0).

`TIGERCLAW_CONFIG` is an additional override that points the runtime
at a specific settings file path, bypassing the data-directory
resolution.

## Settings schema

| Field                  | Type     | Default | Meaning                                                       |
|------------------------|----------|---------|---------------------------------------------------------------|
| `log_level`            | enum     | `info`  | Minimum log level: `debug`, `info`, `warn`, `err`             |
| `mode`                 | enum     | `run`   | Harness mode: `run`, `bench`, `replay`, `eval`                |
| `max_tool_iterations`  | u32      | 1000    | Tool-call iterations per turn before the agent loop gives up  |
| `max_history_messages` | u32      | 100     | Messages retained in-memory before compaction fires           |
| `monthly_budget_cents` | u64      | 0       | Monthly spend cap in cents; `0` disables the cap              |

Example `settings.json`:

```json
{
  "log_level": "warn",
  "mode": "run",
  "max_tool_iterations": 50,
  "max_history_messages": 200,
  "monthly_budget_cents": 5000
}
```

Unknown enum values are rejected at parse time; unknown fields are
ignored when `ignore_unknown_fields` is on (the default for the
runtime loader).

## Environment overrides

Every settings field has a `TIGERCLAW_*` env var that overrides it.
Values are parsed once at startup; an invalid value fails the boot
with `error.InvalidEnvValue` rather than silently degrading.

| Env var                          | Field                  | Format                                |
|----------------------------------|------------------------|---------------------------------------|
| `TIGERCLAW_LOG_LEVEL`            | `log_level`            | `debug` \| `info` \| `warn` \| `err`  |
| `TIGERCLAW_MODE`                 | `mode`                 | `run` \| `bench` \| `replay` \| `eval`|
| `TIGERCLAW_MAX_TOOL_ITERATIONS`  | `max_tool_iterations`  | decimal u32                           |
| `TIGERCLAW_MAX_HISTORY_MESSAGES` | `max_history_messages` | decimal u32                           |
| `TIGERCLAW_MONTHLY_BUDGET_CENTS` | `monthly_budget_cents` | decimal u64                           |

Examples:

```sh
TIGERCLAW_LOG_LEVEL=debug ./zig-out/bin/tigerclaw doctor
TIGERCLAW_MAX_TOOL_ITERATIONS=10 ./zig-out/bin/tigerclaw agent
```

The override layer's grammar is intentionally narrow: one var per
field, no nested syntax, no comma-separated lists. Complex
configuration belongs in `settings.json`.

## Other env vars

| Env var                  | Purpose                                             |
|--------------------------|-----------------------------------------------------|
| `TIGERCLAW_HOME`         | Override the data directory root                    |
| `TIGERCLAW_CONFIG`       | Point at a specific `settings.json` path            |
| `TIGERCLAW_VCR_MODE`     | Harness VCR mode: `replay`, `record`, `passthrough` |
| `XDG_CONFIG_HOME`        | XDG fallback for the data directory                 |
| `HOME`                   | Final fallback for the data directory               |

Provider-specific keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, AWS env for Bedrock) are read by the
respective extension modules. They are not part of the settings
schema and never written to `settings.json`.

## Reload

Hot reload of `settings.json` lands in v0.2.0. Today the runtime
reads settings once at boot; changes require a restart.
