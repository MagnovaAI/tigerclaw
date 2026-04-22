# Trace format

tigerclaw writes traces as **JSON-lines** files. The first line is a header (`Envelope`); subsequent lines are `Span` records. Readers must gate on the header's `schema_version` before interpreting anything else.

## Envelope (line 1)

```json
{
  "schema_version": 2,
  "trace_id": "trace-abc",
  "run_id": "run-42",
  "started_at_ns": 1700000000000000000,
  "mode": "run",
  "dataset_hash":  {"hex": ""},
  "golden_hash":   {"hex": ""},
  "rubric_hash":   {"hex": ""},
  "mutation_hash": {"hex": ""}
}
```

- `schema_version` — pinned to `2` at the time of writing. A reader that does not recognise the version returns `error.UnsupportedSchema`.
- `mode` — `run | bench | replay | eval`. Matches `settings.schema.Mode` by hand; the trace format is the on-disk source of truth because traces outlive binaries.
- Hash slots — see [adr/0009_bench_invariants.md](adr/0009_bench_invariants.md). Empty hex means "not pinned".

## Span (subsequent lines)

```json
{
  "id": "span-1",
  "parent_id": "span-0",
  "trace_id": "trace-abc",
  "kind": "tool_call",
  "name": "read_file",
  "started_at_ns": 100,
  "finished_at_ns": 250,
  "status": "ok",
  "attributes_json": "{\"path\":\"/tmp/x\"}"
}
```

- `kind` — `root | turn | provider_request | tool_call | context_op | custom`.
- `status` — `ok | err | cancelled`.
- `finished_at_ns` is nullable. A null finish denotes an open span that was flushed at crash time.
- `attributes_json` is opaque JSON. Pipe it through `trace.redact.redactSpan` before writing to a user-visible sink.
- IDs must be deterministic across identical runs; callers source them from `determinism.Rng` (see [DETERMINISM.md](DETERMINISM.md)).

## Reading and writing

| Operation | API |
|---|---|
| Write envelope + spans | `trace.Recorder.init(writer)`, then `writeEnvelope` + `writeSpan`. |
| Read a full trace | `trace.replayer.replayFromBytes(allocator, bytes)` → arena-backed `Replay`. |
| Structural diff | `trace.diff.diff(allocator, expected_spans, actual_spans)`. |
| Build a fixture in memory | `trace.fixture.Builder`. |
| Render a compact human view | `trace.exporter.render`. |
| Redact secrets | `trace.redact.redactSpan`. |
| Summarise tool usage | `trace.tool_use_summary.summarize`. |

## See also

- [adr/0003_trace_format.md](adr/0003_trace_format.md)
- [adr/0009_bench_invariants.md](adr/0009_bench_invariants.md)
- [VCR_FORMAT.md](VCR_FORMAT.md) — the sibling format for HTTP record/replay.
