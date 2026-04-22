# tigerclaw

A self-hostable agent runtime in Zig. One binary; an HTTP gateway that
fronts the runtime; pluggable channel adapters that fan inbound human
messages into a single dispatch pipeline and fan replies back out.

## Status

Alpha. The runtime, gateway HTTP surface, channel dispatch FIFO, and
the Telegram adapter are on `main`. Live agent reasoning, persistent
sessions, multi-agent fan-out, and CLI control of the gateway daemon
are not yet wired — see "What works today" below.

## Requirements

- [Zig 0.16.0](https://ziglang.org/download/) — pinned. Earlier and
  later versions will not compile.
- POSIX (macOS, Linux). Windows is not yet a target.

## Build

```sh
zig version          # must be 0.16.0
zig build            # produces ./zig-out/bin/tigerclaw
zig build test       # full test suite — must pass with zero leaks
```

## Quickstart

```sh
zig build
./zig-out/bin/tigerclaw doctor                # environment report
./zig-out/bin/tigerclaw --help                # verb list
./zig-out/bin/tigerclaw channels list         # channel inventory
./zig-out/bin/tigerclaw cassette list         # recorded HTTP fixtures
```

The full walkthrough is in [QUICKSTART.md](QUICKSTART.md).

## Architecture

```
   upstream services           +-----------------+
   (Telegram, ...)             | channel adapter |
                               +--------+--------+
                                        |
                                        v
                       +---------------------------------+
                       | dispatch FIFO (bounded, drop-   |
                       | oldest backpressure)            |
                       +----------------+----------------+
                                        |
                                        v
                            +-----------------------+
                            | agent runner          |
                            | (mock today, react    |
                            |  loop in v0.2.0)      |
                            +-----------+-----------+
                                        |
                                        v
                       +---------------------------------+
                       | outbox (durable, ack-on-deliver)|
                       +----------------+----------------+
                                        |
                                        v
                            +-----------------------+
                            | channel adapter (out) |
                            +-----------+-----------+
                                        |
                                        v
                                 upstream services

       HTTP clients
            |
            v
      +-----------+
      |  gateway  |  ----- read/write the same dispatch FIFO + outbox
      +-----------+
```

The CLI verbs (`agent`, `channels`, `cassette`) are HTTP clients that
talk to the gateway over loopback.

## What works today

| Surface                 | Status                                              |
|-------------------------|-----------------------------------------------------|
| Build + test            | Stable on Zig 0.16.0                                |
| Settings layer          | JSON file + `TIGERCLAW_*` env overrides             |
| Gateway HTTP routes     | Mock backend; see [docs/GATEWAY.md](docs/GATEWAY.md)|
| Channel spec + Telegram | In tree; not yet auto-started                       |
| Inbound dispatch FIFO   | Bounded, drop-oldest, mutex-guarded                 |
| Outbox                  | JSONL append-only with cursor + ack                 |
| VCR cassettes           | Replay path live, record path harness-only          |
| CLI `agent` / `cassette` / `channels` / `doctor` / `completion` | Wired |
| CLI `gateway start/stop`| Parser only — daemon dispatch lands in v0.2.0       |
| CLI `sessions list/get` | Not yet wired                                       |

## Documentation

- [QUICKSTART.md](QUICKSTART.md) — first run, in five minutes.
- [docs/GATEWAY.md](docs/GATEWAY.md) — HTTP API reference.
- [docs/CHANNELS.md](docs/CHANNELS.md) — adding a new channel adapter.
- [docs/CONFIG.md](docs/CONFIG.md) — settings schema + env overrides.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — internal structure.
- [AGENTS.md](AGENTS.md) — engineering protocol for contributors.

## Contributing

Read [AGENTS.md](AGENTS.md) before opening a PR. Conventional commit
subjects; every commit must compile; every commit must pass
`zig build test` with zero leaks.

## License

[MIT](LICENSE).
