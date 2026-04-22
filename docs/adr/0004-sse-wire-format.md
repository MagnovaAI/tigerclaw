# ADR 0004: Turn streaming uses Server-Sent Events with `token` and `done` events

**Status:** Accepted (v0.1.0)

## Context

The turn endpoint `POST /sessions/:id/turns` has two consumers: a
JSON client that wants a single final response, and a streaming
client (the `tigerclaw agent` CLI today, a browser or IDE tomorrow)
that wants to render tokens as they arrive. Both client shapes are
real; neither should have to use a different URL.

The SSE branch in
[`src/gateway/routes.zig`](../../src/gateway/routes.zig) is selected
by content negotiation on `Accept: text/event-stream`. The current
mock body is verbatim:

```
event: token
data: ping

event: done
data: {"completed":true}

```

The two event types map onto the two things a streaming client needs
to know: "here is a fragment of the assistant's reply" and "the turn
is over, here is the completion envelope". The `done` event carries
structured JSON so future metadata (token counts, cost, truncation
flags) can land without inventing a third event type.

Alternatives we considered and rejected:

- **WebSockets** — full duplex, framing complexity, no benefit for a
  server-push use case.
- **Chunked JSON streams** — parsing half a JSON document is fragile;
  every consumer has to hand-roll it.
- **A separate `/turns/stream` path** — doubles the route surface and
  splits auth, logging, and rate-limiting in two.

## Decision

Streaming uses SSE on the same `/sessions/:id/turns` path, with
content negotiation doing the dispatch. The wire format is exactly
two event types:

- `event: token` with `data: <fragment>` — one fragment of assistant
  output. Multiple `token` events may precede a `done`.
- `event: done` with `data: <json>` — terminator. The JSON object
  carries at minimum `{"completed":true}`; more fields may land in
  future versions without breaking consumers that ignore unknown
  keys.

Response headers are
`content-type: text/event-stream; charset=utf-8` and
`cache-control: no-cache`.

## Consequences

- In v0.1.0 the full SSE body is assembled and returned as one
  `http.Response` value. Real per-token flushing requires widening
  the dispatcher to a streaming-response shape; that work is v0.2.0.
  Clients already see the SSE framing, so the upgrade is a latency
  improvement, not a protocol change.
- Cancellation is on a separate route:
  `DELETE /sessions/:id/turns/current` flips a cooperative interrupt
  flag that the runner checks between steps. SSE streams do not need
  a per-connection cancel message — closing the HTTP response at the
  server end is enough once streaming is live.
- Browsers can consume the stream via `EventSource` with no extra
  tooling. This matters for any future inspector UI.
- Unknown-event tolerance is part of the contract: a future
  `event: usage` or `event: tool_call` can land without breaking
  clients that only handle `token` and `done`. Consumers must ignore
  event types they don't recognise rather than error.
- Comment lines (`: keepalive`) may be inserted to keep intermediaries
  from closing idle connections. Consumers ignore them per the SSE
  spec; today we do not emit any.
