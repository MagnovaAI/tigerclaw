# Quickstart

Get tigerclaw built, run a sanity check, and see the CLI surface
that exists on `main` today.

## 1. Build

```sh
zig version          # must report 0.16.0
zig build            # produces ./zig-out/bin/tigerclaw
```

A clean build takes 30–60 seconds on first run; subsequent rebuilds
are seconds thanks to the Zig cache.

## 2. Environment check

`doctor` prints the Zig version, OS/arch, and the resolved config
locations the runtime would use:

```sh
./zig-out/bin/tigerclaw doctor
```

Sample output:

```
zig:        0.16.0
os/arch:    macos / aarch64
HOME:       /Users/you
XDG_CONFIG: <unset>
TIGERCLAW_CONFIG: <unset>
```

## 3. List the available verbs

```sh
./zig-out/bin/tigerclaw --help
```

You should see `agent`, `cassette`, `channels`, `doctor`,
`completion`, `version`, and `help`.

## 4. Inspect channels

The channel inventory is plumbing-only in v0.1.0; the listing is a
static row per known channel kind:

```sh
./zig-out/bin/tigerclaw channels list
./zig-out/bin/tigerclaw channels status
```

Telegram acknowledges the enable/disable verbs but config writeback
lands in v0.2.0:

```sh
./zig-out/bin/tigerclaw channels telegram enable
./zig-out/bin/tigerclaw channels telegram disable
```

## 5. Inspect VCR cassettes

```sh
./zig-out/bin/tigerclaw cassette list
./zig-out/bin/tigerclaw cassette show tests/cassettes/anthropic_basic.jsonl
./zig-out/bin/tigerclaw cassette replay tests/cassettes/anthropic_basic.jsonl
```

`tests/cassettes/` is empty on `main` today; recording happens via the
test harness when `TIGERCLAW_VCR_MODE=record` and the relevant API
key env var are set.

## 6. Talk to the gateway (when it is running)

The gateway daemon is implemented but not yet wired into the CLI's
`gateway start` arm. To exercise the route surface you can run the
gateway tests, or — once the daemon dispatch arm lands in v0.2.0 —
start it and point `agent` at it:

```sh
# v0.2.0:
# tigerclaw gateway start --foreground
# tigerclaw agent --session mock-session
```

The mock runner echoes a fixed reply (`ping`) and frames it in SSE
when `Accept: text/event-stream` is set. The CLI verb does the
content negotiation for you. See [docs/GATEWAY.md](docs/GATEWAY.md)
for the wire format.

## 7. Stop

The daemon process responds to SIGINT (Ctrl-C) and SIGTERM. The CLI
`agent` verb installs its own SIGINT handler that fires a best-effort
`DELETE /sessions/<id>/turns/current` to ask the gateway to cancel
the in-flight turn before exiting with status 130.

## State on disk

The runtime resolves its data directory in this order:

1. `$TIGERCLAW_HOME` — explicit override.
2. `$XDG_CONFIG_HOME/tigerclaw` — XDG convention.
3. `$HOME/.tigerclaw` — fallback default.

Inside that directory the runtime writes:

- `settings.json` — user settings (see [docs/CONFIG.md](docs/CONFIG.md)).
- `outbox/<channel>.jsonl` — durable outbound queue.
- `sessions/<id>.json` — session state (when sessions land).

## Next steps

- Read [docs/GATEWAY.md](docs/GATEWAY.md) for the HTTP API.
- Read [docs/CHANNELS.md](docs/CHANNELS.md) to add a channel adapter.
- Read [docs/CONFIG.md](docs/CONFIG.md) for every settings field.
