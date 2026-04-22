# ADR 0003 — Trace format

**Status:** Accepted.

## Context

The harness produces a trace for every run. Replay, diff, and bench all depend on the trace; the format has to be simultaneously easy to append to, easy to stream back, and easy to verify across versions. The runtime also must never silently accept a trace written by an incompatible build — a version mismatch has to stop the reader.

## Decision

Trace files are **JSON-lines**. The first line is a header (`schema.Envelope`). Subsequent lines are `Span` records, in the order the recorder saw them. Readers MUST call `schema.checkVersion` before interpreting any other field; a mismatch returns `error.UnsupportedSchema`.

The on-disk format is the source of truth — the enum `trace.schema.Mode` mirrors `settings.schema.Mode` by hand rather than the other way around, because traces outlive the binary that wrote them.

## What a span records

- `id`, `parent_id`, `trace_id` — deterministic IDs. The caller generates them via a seeded RNG (see ADR 0006).
- `kind` — `root | turn | provider_request | tool_call | context_op | custom`.
- `name` — human-meaningful label.
- `started_at_ns`, `finished_at_ns` — nullable finish so open spans can be flushed at crash time without a synthesised end.
- `status` — `ok | err | cancelled`.
- `attributes_json` — optional opaque JSON blob; redacted via `trace.redact` before any log or export.

## What is NOT in a span

- Wall-clock timestamps with microsecond drift — the trace wants monotonic `i128` nanoseconds. Wall-clock presentation is the exporter's job.
- Un-redacted secrets. `trace.redact` is an invariant, not a suggestion.
- Provider-specific payloads. Those live in VCR cassettes.

## Alternatives considered

- **Protobuf.** Adds a dependency and a code-gen step for a single-consumer format. JSON-lines lets every existing tool in the repo (`std.json`, the diff helper, the exporter) touch the file without marshalling.
- **Single giant JSON document.** Makes append impossible without rewriting the file.
- **Best-effort parse on version mismatch.** Silently drops load-bearing fields. The reader must fail loudly instead.

## Consequences

- Appenders write single lines; readers split on `\n`. Empty lines are tolerated and skipped.
- `schema_version` is bumped on any field semantics change. Tests in `schema.zig` trip-wire the bump.
- `redact` lives beside the schema, not above it — emitters are expected to pipe through it before writing to any sink a user can read (logs, exported fixtures, CI artifacts).
