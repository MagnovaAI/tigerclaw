# Gateway HTTP API

The gateway is an HTTP front door that exposes the runtime over
loopback. It binds to `127.0.0.1:8765` by default and speaks plain
HTTP/1.1 (no TLS — production deployments are expected to put a
reverse proxy in front if exposed beyond localhost).

The route table lives in `src/gateway/routes.zig`. This document
mirrors that file; if the two disagree, the source wins.

## Routes

| Method | Path                                  | Purpose                                        |
|--------|---------------------------------------|------------------------------------------------|
| GET    | `/health`                             | Liveness probe                                 |
| GET    | `/sessions`                           | List sessions                                  |
| POST   | `/sessions`                           | Create a session                               |
| GET    | `/sessions/:id`                       | Fetch one session                              |
| DELETE | `/sessions/:id`                       | Delete a session                               |
| POST   | `/sessions/:id/messages`              | Enqueue an inbound message (channel ingress)   |
| POST   | `/sessions/:id/turns`                 | Run one turn; JSON or SSE per `Accept`         |
| DELETE | `/sessions/:id/turns/current`         | Cancel the in-flight turn (idempotent)         |

`POST /config/reload` is upcoming in v0.2.0 and is not on `main` today.

## Auth

The gateway accepts an optional bearer token via the `Authorization`
header:

```
Authorization: Bearer <token>
```

When the token is absent the gateway tolerates the request — loopback
is treated as trusted by default. Set
`TIGERCLAW_GATEWAY_REQUIRE_AUTH=1` (in v0.2.0) to require the
header. The CLI's `agent` and `cassette telegram test` verbs forward a
token via `--bearer <token>` when supplied.

## `GET /health`

Liveness probe. Always returns 200 with a small JSON body:

```http
GET /health HTTP/1.1
Host: 127.0.0.1:8765

HTTP/1.1 200 OK
content-type: application/json; charset=utf-8

{"status":"ok"}
```

## `GET /sessions`

Returns the list of known sessions. In v0.1.0 the mock backend always
returns an empty array; persistent sessions land with the runner
rewrite in v0.2.0.

```http
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8

{"sessions":[]}
```

## `POST /sessions`

Creates a session and returns its id. The mock backend always returns
the canned id `mock-session` so tests are deterministic.

```http
HTTP/1.1 201 Created
content-type: application/json; charset=utf-8

{"id":"mock-session"}
```

## `GET /sessions/:id`

Returns one session. The mock backend recognises only `mock-session`
and 404s for anything else.

```http
GET /sessions/mock-session HTTP/1.1

HTTP/1.1 200 OK
{"id":"mock-session","turns":0}
```

## `DELETE /sessions/:id`

Deletes a session. Returns 204 with no body.

## `POST /sessions/:id/messages`

Enqueues an inbound message into the dispatch FIFO. The body shape is
channel-specific. Returns 202 Accepted as soon as the message is on
the queue; the runner picks it up asynchronously.

```http
POST /sessions/mock-session/messages HTTP/1.1
content-type: application/json

{"channel":"telegram","to":"123","text":"hi"}

HTTP/1.1 202 Accepted
```

## `POST /sessions/:id/turns`

Runs one turn synchronously. The response body shape is decided by the
client's `Accept` header.

### Default — `application/json`

```http
POST /sessions/mock-session/turns HTTP/1.1

HTTP/1.1 200 OK
content-type: application/json; charset=utf-8

{"status":"ok"}
```

### Streaming — `text/event-stream`

When the `Accept` header includes `text/event-stream` the gateway
responds with a Server-Sent Events stream. The mock runner emits a
single `token` event followed by a terminal `done` event:

```http
POST /sessions/mock-session/turns HTTP/1.1
Accept: text/event-stream

HTTP/1.1 200 OK
content-type: text/event-stream; charset=utf-8
cache-control: no-cache

event: token
data: ping

event: done
data: {"completed":true}

```

The `Accept` match is a substring check: a header like
`application/json, text/event-stream;q=0.9` still selects SSE.

### Wire format

Each event is two lines plus a blank-line separator:

```
event: <name>
data: <utf-8 payload>

```

Defined event names:

| Event   | Data                          | Meaning                       |
|---------|-------------------------------|-------------------------------|
| `token` | A token's text                | Append to the rendered output |
| `done`  | `{"completed":true}` or error | Terminal event; close stream  |

Unknown events MUST be ignored by clients.

## `DELETE /sessions/:id/turns/current`

Cancels the in-flight turn for `:id`. Idempotent — returns 204
whether or not a turn was actually in flight, so a Ctrl-C handler
can fire it without tracking turn state.

```http
DELETE /sessions/mock-session/turns/current HTTP/1.1

HTTP/1.1 204 No Content
```

In v0.1.0 the mock runner has a single global cancel flag; per-session
cancel routing lands with the react-loop runner.

## Error responses

| Status | Body                       | When                                       |
|--------|----------------------------|--------------------------------------------|
| 400    | `<reason>\n` (text)        | Path param missing or malformed body       |
| 401    | empty                      | Bearer required + missing/invalid          |
| 404    | empty                      | Unknown session id                         |
| 429    | `budget exceeded\n` (text) | Monthly budget cap hit                     |
| 500    | empty                      | Internal error (handler crash, no context) |

Clients should treat any 5xx as transient and surface it to the
operator rather than retrying without bound.
