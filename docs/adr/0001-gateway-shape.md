# ADR 0001: Gateway is a single long-running HTTP/SSE process

**Status:** Accepted (v0.1.0)

## Context

Tigerclaw needs to bridge three concerns that all want to touch the same
runtime state: CLI verbs (`tigerclaw agent`, `tigerclaw sessions list`,
`tigerclaw providers status`), inbound channel adapters (Telegram today,
more later), and eventually browser-based tooling for inspection. The
canonical options were:

- A set of per-channel daemons with their own IPC surfaces.
- A library-only embedding with CLIs spawning fresh processes each call.
- One long-running daemon exposing a shared API.

The route table in [`src/gateway/routes.zig`](../../src/gateway/routes.zig)
shows the shape we settled on — a small REST surface plus an SSE branch
on the turn endpoint:

```
GET    /health
POST   /config/reload
GET    /sessions
POST   /sessions
GET    /sessions/:id
DELETE /sessions/:id
POST   /sessions/:id/messages
POST   /sessions/:id/turns               (JSON or text/event-stream)
DELETE /sessions/:id/turns/current
```

HTTP won the transport coin toss for pragmatic reasons: `curl` and a
browser are sufficient debugging tools, SSE is already the lingua franca
for LLM token streaming (Anthropic and OpenAI both speak it), and a
single listener on localhost means one place to enforce bearer auth
rather than one per socket.

## Decision

The gateway is a single long-running process. Every other surface talks
to it over localhost HTTP. `tigerclaw gateway start` is the one daemon;
every CLI verb that does work (`agent`, `sessions`, `channels status`,
`config reload`) is a short-lived client of that daemon. The channel
manager, the dispatch queue, the outbox, the in-flight-turn counter,
and the shutdown drain all live inside the gateway process and share
memory directly.

Streaming uses SSE on the same `/sessions/:id/turns` path, selected by
`Accept: text/event-stream`. See
[ADR 0004](./0004-sse-wire-format.md) for the wire-format details.

## Consequences

- The gateway IS the daemon. If it dies, inbound messaging and CLI
  verbs both stop working. Mitigation is fast restart plus crash-safe
  outbox state (`src/channels/outbox.zig` fsyncs every append), so a
  restart picks up undelivered replies without loss.
- All shared state — sessions, in-flight counters, reload generation —
  is in-process. No distributed consensus, no cross-process locks.
  A single writer per session is the whole story.
- The boot layer in
  [`src/gateway/boot.zig`](../../src/gateway/boot.zig)
  owns the drain ordering: stop accepting, wait for in-flight turns,
  stop channel receivers, flush outbox, close. Getting this order
  wrong drops work; keeping it in one module keeps it reviewable.
- Horizontal scale-out is explicitly out of scope. v0.1.0 targets one
  operator's machine. Multi-node coordination, if it ever arrives, is
  v0.2.0 work and will warrant its own ADR.
- Authentication is a single bearer check at the HTTP boundary. CLIs
  read the token from settings; there is no per-route policy yet.
