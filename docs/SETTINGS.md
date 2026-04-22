# Settings

The runtime reads every tunable from a single layered source. The layers, from lowest to highest precedence:

1. **Compiled defaults** — `src/constants/defaults.zig`.
2. **Config file** — JSON parsed into `src/settings/schema.zig::Settings`. Path resolved by `managed_path.zig` (`flag > env > xdg > home`).
3. **Environment variables** — every `TIGERCLAW_<FIELD>` env var maps onto a schema field via `env_overrides.zig`.
4. **MDM overlay** — optional machine-wide policy via `mdm.zig`. Beats env and runtime patches.
5. **Runtime patches** — `apply_change.zig` installs atomic single-field updates into the in-memory `Cache`.

## Lifecycle

```
load time:       defaults   →   config file   →   env vars   →   mdm   →   cache.install()
runtime:                                              apply_change.apply() → cache.install()
```

- The loader always validates before installing. Invalid settings fail the load; nothing partial lands.
- Every install bumps `Cache.generation`, so observers can detect staleness without diffing.

## Files

- [`schema.zig`](../src/settings/schema.zig) — the `Settings` struct and its enum types (`LogLevel`, `Mode`).
- [`validation.zig`](../src/settings/validation.zig) — field-level invariants. Multiple issues reported per pass.
- [`managed_path.zig`](../src/settings/managed_path.zig) — deterministic config-path resolution. Pure.
- [`env_overrides.zig`](../src/settings/env_overrides.zig) — `TIGERCLAW_*` application via a `Lookup` vtable.
- [`cache.zig`](../src/settings/cache.zig) — in-memory snapshot and generation counter.
- [`apply_change.zig`](../src/settings/apply_change.zig) — safe single-field patch. On failure the cache is unchanged.
- [`settings.zig`](../src/settings/settings.zig) — the high-level `loadFromBytes` loader.
- [`internal_writes.zig`](../src/settings/internal_writes.zig) — atomic writes of settings files. Nothing else in this subsystem mutates the filesystem.
- [`change_detector.zig`](../src/settings/change_detector.zig) — `poll()`-based external-edit detection.
- [`secrets.zig`](../src/settings/secrets.zig) — canonical secret-key list and a `redact()` helper.
- [`mdm.zig`](../src/settings/mdm.zig) — MDM-managed overlay (interface only today).

## Environment variables

| Variable | Maps to | Notes |
|---|---|---|
| `TIGERCLAW_CONFIG` | path resolution | Beats XDG defaults; beaten by `--config`. |
| `TIGERCLAW_LOG_LEVEL` | `log_level` | `debug | info | warn | err`. |
| `TIGERCLAW_MODE` | `mode` | `run | bench | replay | eval`. |
| `TIGERCLAW_MAX_TOOL_ITERATIONS` | `max_tool_iterations` | Decimal u32. |
| `TIGERCLAW_MAX_HISTORY_MESSAGES` | `max_history_messages` | Decimal u32. |
| `TIGERCLAW_MONTHLY_BUDGET_CENTS` | `monthly_budget_cents` | Decimal u64. |

Invalid values fail the load with `error.InvalidEnvValue` — the runtime refuses to start rather than silently fall back.

## Secrets

Secrets are never embedded in the main config. They live next to it in `.secret.jsonc` (same layered precedence). The `redact()` helper replaces any value whose key ends in `_api_key`, `_token`, `_password`, or `_secret` with `"***"`. Use it before writing to logs, traces, or exported fixtures.

## See also

- [adr/0007_settings_layering.md](adr/0007_settings_layering.md)
- [adr/0022_error_taxonomy.md](adr/0022_error_taxonomy.md)
