# VCR cassette format

A VCR cassette records HTTP request/response pairs so the runtime can replay provider traffic without hitting the network. Cassettes are shaped like traces — **JSON-lines**, header-first — because tigerclaw is the only reader and keeping one parser shape saves code.

## Header (line 1)

```json
{"format_version": 1, "cassette_id": "fixture-1", "created_at_ns": 1700000000000000000}
```

`format_version` is pinned to `1`. A mismatched version returns `error.UnsupportedFormat`.

## Interaction (subsequent lines)

```json
{
  "request":  {"method": "POST", "url": "https://api.example.test/v1/chat", "body": "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"},
  "response": {"status": 200, "body": "{\"text\":\"hello\"}"}
}
```

`request.body` is nullable; a null body matches only another null body under the default policy.

## Matching

`matcher.Policy` is strict by default: method, url, and body must all be byte-equal. A caller that wants looser matching sets `.body = false` or `.url = false` explicitly — defaults never degrade.

Interactions are **consumed on match.** `Cassette.find` marks each matched interaction and never re-serves it on the same playback. Repeated identical requests therefore require repeated recordings.

## Why JSON-lines (not YAML)

The TREE originally called for YAML cassettes. Zig 0.16 has no std YAML, tigerclaw is the only reader, and the trace subsystem already speaks JSON-lines. Using YAML would add a parser dependency for no observable benefit.

## API

| Operation | API |
|---|---|
| Write header + interactions | `vcr.Recorder.init(writer)`, then `writeHeader` + `writeInteraction`. |
| Read back | `vcr.replayer.replayFromBytes(allocator, bytes)` → arena-backed `Cassette`. |
| Match a live request | `Cassette.find(policy, request)` → `?Response`. |

## See also

- [TRACE_FORMAT.md](TRACE_FORMAT.md) — same shape, one line per record, version-gated reader.
