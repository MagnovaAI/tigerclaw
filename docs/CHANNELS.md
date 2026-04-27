# Channels

A channel is anything that can deliver inbound human messages and
accept outbound replies — Telegram today; Slack, iMessage, Discord,
Signal as future adapters. The runtime treats every channel through
one small vtable so the dispatch core stays adapter-agnostic.

## The vtable

The contract lives in `src/channels/spec.zig`. A channel exposes:

```zig
pub const Channel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        id: *const fn (ptr: *anyopaque) ChannelId,
        send: *const fn (ptr: *anyopaque, msg: OutboundMessage) SendError!void,
        receive: *const fn (
            ptr: *anyopaque,
            buf: []InboundMessage,
            cancel: *const std.atomic.Value(bool),
        ) ReceiveError!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };
};
```

| Method     | Thread that calls it          | Contract                                                |
|------------|-------------------------------|---------------------------------------------------------|
| `id`       | Any                           | Pure; returns the `ChannelId` enum tag                  |
| `send`     | Dispatch worker               | Synchronous; outbox manages retries — do NOT loop       |
| `receive`  | The channel's own poll thread | Blocks until a message arrives or `cancel` flips        |
| `deinit`   | Manager (shutdown)            | Release HTTP client, polling state, channel allocator   |

A single `Channel` value's `send` and `receive` are not designed to
run concurrently on the same instance. The channel manager guarantees
exclusive ownership.

`receive` MUST observe the `cancel` atomic with `.acquire` ordering so
any message buffered before cancellation is still visible when the
receiver wakes.

## Message types

```zig
pub const InboundMessage = struct {
    upstream_id: u64,           // monotonic per (channel, conversation)
    conversation_key: []const u8,
    thread_key: ?[]const u8 = null,
    sender_id: []const u8,
    text: []const u8,
};

pub const OutboundMessage = struct {
    conversation_key: []const u8,
    thread_key: ?[]const u8 = null,
    text: []const u8,
};
```

## String lifetimes

`InboundMessage` borrows every string slice. The channel adapter MUST
keep those strings alive until the dispatch worker has consumed the
message — meaning either:

- own them on the adapter's allocator and free them via a `freeInbound`
  helper after the dispatcher returns; or
- copy them into the dispatcher's arena before returning from
  `receive`.

The Telegram adapter takes the first approach; see
[`extensions/channel-telegram/channel.zig`](../extensions/channel-telegram/channel.zig)
for the canonical pattern. The free helper is invoked by the channel
manager once the message clears the FIFO.

`OutboundMessage` is owned by the caller of `send`; the adapter must
not retain references past return.

## Errors

```zig
pub const SendError = error{
    BadRequest,
    Unauthorized,
    RateLimited,
    TransportFailure,
};

pub const ReceiveError = error{
    Unauthorized,
    TransportFailure,
};
```

The dispatch worker maps `RateLimited` to a backoff; `Unauthorized` is
fatal for the channel and bubbles up to the manager which will
shut the adapter down and surface a configuration error.

## Adding a new channel

Suppose you are adding `slack`. Steps:

1. **Create the extension directory.**

   ```
   extensions/channel-slack/
     api.zig       # raw HTTP client for the upstream API
     channel.zig   # implements the Channel vtable on top of api.zig
     root.zig      # public surface; re-exports init / deinit
   ```

   Naming is locked: `extensions/channel-<name>/`. Underscores in
   module ids mirror the directory name.

2. **Register the named module in `build.zig`.**

   Mirror the existing `channel_telegram` registration. The module id
   is `channel_slack`. Imports allowlisted to the channel module are
   `std`, `channels_spec`, and `build_options` — anything else fails
   the build with a "module not declared in dependency list" error.

3. **Add a `-Denable_slack` build option** that gates the comptime
   inclusion of the adapter so users can compile a smaller binary
   when a channel isn't needed.

4. **Add a comptime shim entry in `src/channels/root.zig`** that
   imports `channel_slack` when the build option is on, and is empty
   when it is off. The shim is the only place `src/` references the
   extension; everything else goes through the `Channel` vtable.

5. **Extend the `ChannelId` enum** in `src/channels/spec.zig` with
   the new tag. Update any switch statements the compiler then
   complains about — switches over `ChannelId` are exhaustive on
   purpose.

6. **Implement the four vtable methods** in
   `extensions/channel-slack/channel.zig`. Keep `send` synchronous;
   keep `receive` blocked on the poll loop with explicit `.acquire`
   reads of the cancel flag.

7. **Tests.** Mirror `extensions/channel-telegram/`'s test style:
   unit tests on the API client with a fake HTTP server (use
   `std.http.Server.receiveHead + request.respond`, never hand-rolled
   bytes), and contract tests on the vtable using the fake channel
   harness in `src/channels/spec.zig`'s test block.

## Reference adapter

`extensions/channel-telegram/` is the smallest working example.
Read it end-to-end before writing a new adapter — the patterns it
establishes (token-bucket rate limiting, JSONL outbox cursor, freeing
inbound strings after dispatch) are the patterns the runtime expects.
