# ADR 0003: Sessions key raw, URL-safe (channel, conversation, thread) triples

**Status:** Accepted (v0.1.0)

## Context

Every inbound message is eventually routed to a per-session state file
on disk. The dispatch layer needs a deterministic function from
`(channel_id, conversation_key, thread_key?)` to a filesystem path so
replies go to the right session, multi-turn conversations resume, and
operators can inspect what the bot believes it knows.

The router in
[`src/channels/router.zig`](../../src/channels/router.zig) is the
canonical implementation. It produces paths of the form:

```
<channel_id>/<conversation_key>[--<thread_key>]/state.json
```

e.g. `telegram/123456/state.json`, or
`telegram/123456--topic17/state.json`.

The on-disk schema is owned by
[`src/harness/state.zig`](../../src/harness/state.zig), which stamps
every file with `schema_version` (currently `2`). Parsing rejects any
file whose version does not match.

Two candidate key strategies existed:

- **Hash** the triple into an opaque id (`sha256(ch|conv|thread)`),
  ensuring bounded path lengths and opaque on-disk naming.
- **Use the keys verbatim**, after validating them against a URL-safe
  character set and rejecting anything that could escape the path.

## Decision

Keys are used verbatim. The router validates each component against
`isUrlSafeKey` and rejects traversal attempts or non-URL-safe bytes
with `ResolveError.InvalidKey` before any filesystem call. Paths that
exceed the caller's buffer surface `ResolveError.PathTooLong` —
there is no silent truncation.

The schema version in `state.json` is checked on every load; files
from an older schema are refused with a clear error rather than
best-effort migrated, so drift is visible instead of hidden.

## Consequences

- An operator running `ls ~/.tigerclaw/instances/default/sessions/telegram/` immediately
  sees which chat each session belongs to. This is the primary win —
  debugging a session is a question of `cat`, not a hash-table
  lookup. The content of `state.json` already contains the full
  conversation, so hashing would cost grep-ability with no real
  privacy gain.
- Long thread keys make long paths. On platforms with tighter
  `PATH_MAX` this can hit the limit. We surface `PathTooLong` rather
  than truncating; the operator can shorten the key or we extend the
  buffer budget explicitly.
- Schema bumps are load-bearing. Each bump requires either a
  migration step or a clean-break upgrade note in the release notes.
  Silent acceptance of older files is explicitly rejected.
- URL-safe validation is the trust boundary between the dispatch
  layer and the filesystem. Any channel adapter that produces a
  different encoding (e.g. Slack thread timestamps) must translate
  before it hands the message off. The dispatch layer is the
  enforcer.
- v0.2.0 may introduce a separate index file that maps human-readable
  aliases to canonical keys; that does not require rethinking the
  on-disk layout, which would stay the source of truth.
