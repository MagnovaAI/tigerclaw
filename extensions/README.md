# extensions/

Optional, build-flag-gated provider implementations. Each `extensions/<category>-<name>/root.zig`
is wired up as its own named Zig module in `build.zig` and is included in the binary
only when its name appears in the `-Dextensions=` selector.

## Build flag

```sh
zig build                                  # default: anthropic,openai,bedrock,openrouter
zig build -Dextensions=anthropic           # only anthropic compiled in
zig build -Dextensions=anthropic,openai,bedrock,openrouter  # subset
zig build -Dextensions=all                 # explicit "all known"
zig build -Dextensions=""                  # zero extensions (mock-only)
```

The shim in `src/llm/providers/root.zig` reads `build_options.enable_<name>` at
comptime and replaces each disabled provider's surface with `void`, so disabling
an extension also strips it from `tigerclaw.llm.providers`.

## Amendment A import allowlist

Code under `extensions/<category>-<name>/` MAY import only:

- `std`
- `types` — the public type surface (`src/types/root.zig`)
- `llm_provider` — the provider trait (`src/llm/provider.zig`)
- `llm_transport` — the streaming/SSE transport (`src/llm/transport/root.zig`)
- `build_options` — comptime feature flags

It MAY NOT import any other named module, MAY NOT use relative `@import` paths
that escape its own `extensions/<category>-<name>/` directory, and MAY NOT depend on
another extension.

**This is enforced by the build system.** Each extension is a separate Zig
module whose `addImport` chain in `build.zig` lists exactly the modules above.
Anything outside that allowlist fails at compile time with
`error: no module named '...'`.

## Adding a new extension

1. Drop `extensions/<category>-<name>/root.zig` exporting a provider type.
2. In `build.zig`: add an `enable_<name>` (the bare extension name, no category prefix) build option, create `<category>_<name>` (e.g. `provider_anthropic`)
   module with the allowlisted `addImport` chain, and `tigerclaw_mod.addImport`
   it inside the `if (enable_<name>)` block.
3. In `src/llm/providers/root.zig`: add the comptime branch and a
   `<Name>Provider` alias mirroring the existing entries.
