# ADR 0002: Channel and provider extensions live behind a build-gated allowlist

**Status:** Accepted (v0.1.0)

## Context

Channels (Telegram today; Slack, iMessage, Discord later) and LLM
providers (Anthropic, OpenAI, Bedrock, OpenRouter) are the two
surfaces that want to grow fastest. Each new one pulls in a
vendor-specific HTTP dialect, a unique rate-limit shape, and occasional
native-dependency churn. Left unchecked, that mass ends up entangled
with dispatch, routing, the agent runner, and the settings layer.

The channel contract is the four-method vtable in
[`src/channels/spec.zig`](../../src/channels/spec.zig) — `id`, `send`,
`receive`, `deinit`. Providers speak the owned-provider interface in
`src/llm/provider.zig`. Those two interfaces are the only surfaces an
extension should need.

[`extensions/README.md`](../../extensions/README.md) states the
allowlist: an extension may import `std`, `channels_spec` (or the
provider-equivalents `types`, `llm_provider`, `llm_transport`), and
`build_options`. Nothing else. The rule is enforced at build time, not
by convention — the `addModule` + `addImport` chain in
[`build.zig`](../../build.zig) literally only wires those imports into
each extension module, so a forbidden `@import("../../src/gateway/…")`
does not resolve.

## Decision

Extensions live under `extensions/<plug-id>/root.zig` and are
registered as their own named Zig modules in `build.zig`. Each is
gated by a `-Dextensions=` build token. The shim in
`src/channels/root.zig` (and the equivalent for providers) pulls each
extension in behind a comptime `if (build_options.enable_<name>)`;
disabled extensions collapse to `struct {}` so dependent code can
`@hasDecl`-check without a runtime branch.

The allowlist is deliberately narrow: extensions do not see peer
subsystems, do not see the gateway router, do not see the agent
runner. If an extension wants to influence agent behaviour, it does
so through the inbound-message pipeline like any other caller.

## Consequences

- Adding a channel is a three-step local change: drop a directory,
  add an `addModule` block to `build.zig`, add a comptime re-export
  to `src/channels/root.zig`. No dispatch, routing, or agent code
  changes.
- `zig build -Dextensions=""` produces a mock-only binary. This is
  the default for unit-test runs that should not dial real APIs, and
  for operators who want a minimum-trust build.
- A request to import `src/llm/...` from a channel extension won't
  compile. If the underlying need is legitimate, the right answer is
  to funnel through the agent runner, not to widen the allowlist.
- Third-party extensions are possible without a fork: the allowlist
  set is small and stable, and anyone who builds their own Zig module
  pointing `root_source_file` at a private extension directory picks
  up exactly the same surface.
- The gate applies uniformly to providers and channels; there is no
  special casing by category. Both live under `extensions/`, both
  follow the same naming and allowlist rules.
