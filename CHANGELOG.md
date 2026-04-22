# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-22

First public release. Single binary, single process, loopback-only by
default. Streaming providers, a Telegram channel, session-keyed
dispatch, a durable outbox, a hot-reloadable settings layer, and a
read-side CLI for inspecting traces, cassettes, channels, and
diagnostics.

### Added

#### Gateway

- HTTP server bound to `127.0.0.1:8765` exposing a small RESTy API:
  `GET /health`, `GET|POST /sessions`, `GET|DELETE /sessions/:id`,
  `POST /sessions/:id/messages`, `POST /sessions/:id/turns`,
  `DELETE /sessions/:id/turns/current`. Routes table lives in
  `src/gateway/routes.zig`; reference docs at
  [docs/GATEWAY.md](docs/GATEWAY.md).
- Pure HTTP router with method overload + path params, transport-
  neutral request/response types, and a request → response
  dispatcher that handlers plug into without owning the wire format.
- Middleware layer covering bearer token auth, request log emission,
  content-type negotiation, and SIGPIPE swallowing.
- Server-Sent Events response on `POST /sessions/:id/turns` when the
  client requests `Accept: text/event-stream` — `event: token` frames
  per token followed by a terminating `event: done` frame.
- Cooperative cancel via `DELETE /sessions/:id/turns/current`,
  idempotent so a Ctrl-C handler can fire it without tracking turn
  state.
- `std.http.Server` adapter that binds the dispatcher to a real TCP
  listener, with end-to-end roundtrip coverage over loopback.
- Boot layer with ordered drain: stop accepting → wait in-flight →
  stop channels → flush outbox → close. Includes a config-reload
  stub that swaps the settings snapshot atomically.
- Per-session budget refusal: turns return `429 Too Many Requests`
  when the session's cost ledger is exhausted.

#### CLI

- Verbs wired and dispatched today: `agent`, `cassette`, `channels`,
  `trace`, `providers`, `models`, `diag`, `gateway` (logs only),
  `doctor`, `completion`, `version`, `help`. Argv-only sub-parsers
  for `agents`, `sessions`, and `config` ship in tree but are not
  yet routed from the main dispatcher.
- Descriptor-driven dispatcher with a presentation layer for
  banner/help table rendering.
- `agent` streams gateway SSE tokens to stdout; SIGINT installs a
  handler that fires the cancel `DELETE` and exits 130.
- `channels list|status|telegram (enable|disable|test)` —
  list/status are plumbing-only in v0.1.0; `telegram test` POSTs a
  smoke message at the gateway.
- `cassette list|show|replay` walks `tests/cassettes/` and replays
  through the VCR replayer.
- `trace list|show|diff` enumerates trace files, renders one line per
  span (capped at 200 with a truncation footer), and runs the
  structural diff in `src/trace/diff.zig`.
- `providers list|status` lists configured providers and probes
  reachability; `models list|status|set` browses the model catalog
  and overrides the per-session model.
- `diag` and `gateway logs` surface the rolling diagnostics buffer
  and daemon log tail respectively.
- `doctor` prints zig version, OS/arch, and the resolved settings
  paths.
- `completion bash|zsh|fish` generates a shell completion script.
- One-shot HTTP client wrapper around `std.http.Client.fetch` shared
  by every gateway-facing verb (typed errors, single retry on
  ConnectionRefused, optional bearer).

#### Channels

- Channel vtable + message types in `src/channels/spec.zig` with a
  locked thread model: one OS thread per channel owns `receive`, a
  single shared dispatch worker drains the FIFO and invokes `send`.
- Bounded inbound FIFO with drop-oldest backpressure (mutex-guarded).
- Per-channel receive threads coordinated by a channel manager;
  cancel observed with `.acquire` ordering so messages buffered before
  cancellation stay visible.
- Conversation router that maps `(channel, conversation_key)` to a
  session path, gating the state schema for inbound traffic.
- Sender allowlist with per-sender token-bucket rate limit (default
  one message per second), wildcard `*` mode for development.
- Durable outbox: append-only JSONL with fsync, cursor + ack flips
  records to delivered, exponential backoff on delivery failures.
- Telegram channel adapter under `extensions/channels-telegram/`:
  Bot API client with token-bucket rate limits, channel vtable
  binding, and end-to-end inbound → dispatch → outbound test against
  a fake upstream HTTP server.

#### LLM providers

- Build-flag-gated extensions under `extensions/providers-*/` with a
  module-isolated allowlist: provider code may import only `std`,
  `types`, `llm_provider`, `llm_transport`, `build_options`.
- Anthropic Messages API live HTTP transport with `cache-control`
  block injection, OAuth path support, and an SSE `streamTokens`
  callback that surfaces incremental deltas to callers.
- OpenAI provider on the same transport surface.
- OpenRouter provider as an OpenAI-compatible aggregator with
  pass-through model selection and a `std.http.Server`-backed fake
  test server.
- Bedrock provider parser (live HTTP wiring is deferred).
- `llm.fromSettings` factory returns an `Owned` handle that the
  caller frees via `owned.deinit(allocator)`; the gateway and CLI
  both consume providers through this single entry point.
- VCR provider contract tests that replay cassettes by default,
  proving the SSE parsers stay compatible with the live wire format.
  Record mode persists fresh cassettes when the matching API key
  env var is set.

#### Daemon

- PID file management: `write`, `read`, `remove`, and an `isStale`
  check that distinguishes a crashed daemon from a live one.
- Append-only log sink with positional writes that survive crashes.
- Bounded shutdown drain helper with a deadline so a stuck handler
  cannot block process exit.

#### Settings

- Layered configuration: defaults (`src/constants/defaults.zig`) →
  JSON file → `TIGERCLAW_*` env overrides → MDM → runtime patches.
- Atomic write helpers with change detection, secret redaction, and
  a managed-path resolver that honours `TIGERCLAW_HOME`,
  `XDG_CONFIG_HOME`, and `HOME` in that order.
- Agents config block with a 1:1 channel validator that refuses
  multi-channel agents in v0.1.0.
- Reference docs at [docs/CONFIG.md](docs/CONFIG.md).

#### Build

- `-Dextensions=<csv>` selector (default
  `anthropic,openai,bedrock,openrouter,telegram`); empty string
  compiles a binary with zero extensions.
- Per-extension build options (`-Denable_<name>`) gate comptime
  inclusion of each adapter so a deployment only links the channels
  and providers it actually uses.
- Module allowlist enforced at build time: extensions reaching
  outside their declared imports surface as a build error rather
  than a runtime surprise.

#### Trace + VCR

- Trace v2 schema (envelope + spans), recorder, replayer, structural
  diff, fixture builder, exporter, and redaction helpers in
  `src/trace/`.
- VCR cassette format under `src/vcr/`: JSON-lines, one header plus
  one interaction per line, replay-by-default with optional record
  mode.

#### Documentation

- [README.md](README.md) — status-honest project overview and
  architecture sketch.
- [QUICKSTART.md](QUICKSTART.md) — five-minute walkthrough of the
  wired CLI verbs.
- [docs/GATEWAY.md](docs/GATEWAY.md) — HTTP API reference with the
  SSE wire format spelled out.
- [docs/CHANNELS.md](docs/CHANNELS.md) — channel vtable, string
  lifetimes, and the recipe for adding a new adapter.
- [docs/CONFIG.md](docs/CONFIG.md) — every settings field plus the
  full env-override grammar.
- ADRs in `docs/adr/` covering repo model, harness scope, trace
  format, determinism, settings layering, bench invariants, the
  budget ledger, and the error taxonomy.

### Deferred to v0.2.0

- True per-token streaming end-to-end. Today the gateway buffers the
  SSE body before sending; the CLI's `agent` verb honours interrupts
  before or after the body lands but not mid-stream.
- Live HTTP wiring for the Bedrock provider (parser is shipped).
- CLI dispatch arms for `gateway start|stop|status|restart|serve`,
  `sessions`, `agents`, and `config`. The argv parsers exist; the
  `main.zig` arms that wire them to the daemon do not.
- Multi-agent fan-out. The settings validator enforces a single
  channel per agent; multi-channel agents land with the agent
  manager rewrite.
- Persistent global model default override. `models set` requires
  `--session` today.
- Real cassette recording for Bedrock.
- Memory engine implementations. The spec vtable ships as a pure
  interface; concrete impls land later.

### Known issues

- The gateway daemon process is not yet started by the CLI. Bringing
  the route surface up requires running the test suite or wiring
  your own bootstrap until the daemon dispatch arms land.
- `tigerclaw trace list` does not expand a leading `~` in `--dir`;
  pass an absolute path or rely on shell tilde expansion.
- Mock runner echoes the literal token `ping` regardless of input —
  real react-loop wiring is the v0.2.0 cut.

### Invariants

- Every commit compiles (`zig build`).
- Every commit passes the full suite with zero leaks
  (`zig build test --summary all`).
- `zig fmt --check src/ extensions/` passes.

## [Unreleased]

Add entries here as work lands post-v0.1.0.
