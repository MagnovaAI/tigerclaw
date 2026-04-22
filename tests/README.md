# tests/

Integration, contract, and end-to-end tests plus their fixtures.

**Unit tests do not live here.** They live at the bottom of the file under test, inside `test "name" {}` blocks. See `AGENTS.md`.

## Conventions

- Each integration test is a standalone `tests/<name>_test.zig` file.
- To register one: add its name (sans `.zig`) to the `integration_tests` slice in `build.zig`. Explicit registration keeps the build graph deterministic.
- Fixtures use `fixture_*` prefixes (`fixture_mock_tool_results.json`, `fixture_vcr_cassette.yaml`, etc.).
- All tests use `std.testing.allocator` with matching `defer ... free(x)`.
- Tests must be deterministic: injected clocks, fixed seeds, `std.testing.tmpDir(.{})` for filesystem state.

## Running

```sh
zig build test --summary all         # all tests
zig test tests/foo_test.zig          # one file during development
```
