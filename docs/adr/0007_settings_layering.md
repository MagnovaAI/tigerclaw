# ADR 0007 — Settings layering

**Status:** Accepted.

## Context

Configuration arrives from several places: compiled defaults, files, env vars, org-wide MDM policy, and runtime patches issued by the harness. Each of those has a caller who expects their value to win. We need one rule.

## Decision

The effective settings value is the left-fold of these layers, lowest precedence first:

1. `constants/defaults.zig`
2. Config file (`schema.zig` via `settings.loadFromBytes`)
3. `TIGERCLAW_*` env vars (`env_overrides.zig`)
4. MDM overlay (`mdm.zig`)
5. Runtime patches (`apply_change.zig`)

Validation runs after step 3 during the initial load. Runtime patches re-run validation on their own scratch value before installing. **No partial state ever lands.** A failed install leaves `Cache.current` and `Cache.generation` untouched.

`managed_path.zig` resolves the config-file location using a parallel precedence: `--config` flag > `TIGERCLAW_CONFIG` env > `XDG_CONFIG_HOME` > `$HOME/.config`.

## Alternatives considered

- **File only; ignore env:** makes container/CI workflows painful because anything config-shaped has to write a file first.
- **Env only; ignore file:** doesn't scale past a handful of tunables and leaks long secrets into process inspection (`ps eww`).
- **Patches as the primary interface:** inverts the dependency — now the harness starts without knowing its budget and hopes for a later patch. Fragile.
- **Merge semantics where any layer can delete prior values:** no concrete need, and it makes "which layer set this?" invisible.

## Consequences

- MDM beats env, which beats file, which beats defaults.
- Runtime patches beat MDM. This is a deliberate choice: the harness owns the active session and must be able to respond to interrupts (cost-cap tightening, mode transitions). MDM governs what the runtime *starts with*, not what it does mid-session.
- Validation is idempotent and total over `Settings` — every field gets checked on every install. This catches the case where a previously valid default becomes invalid because of an overlay combination.
- `Cache.generation` is a monotonic counter. Consumers can cheaply detect staleness by comparing the generation they last observed to the current one; they never have to deep-compare the struct.
