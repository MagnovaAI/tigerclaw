# Contract tests

Every plugger ships with a contract suite — a set of invariants
every plug claiming that capability must satisfy. Contract tests live
here so they're centralized and reusable.

## Layout

```
src/contract_runner.zig  shared Harness helper (lives with src/ because
                         @embedFile and module-boundary rules apply)
tests/contract/
├── README.md           this file
└── <plugger>/          one dir per plugger
    └── contract.zig    exports `runForPlug(args)` invoked by plugs
```

## Writing a new contract

When a new plugger lands (e.g. `memory`), add:

```
tests/contract/memory/contract.zig
```

Exports `runForPlug` that the plug's own test block calls:

```zig
// tests/contract/memory/contract.zig
const runner = @import("tigerclaw").contract_runner;
const Memory = @import("tigerclaw").plug.memory.Memory;

// Harness is built in place (it holds a pointer back into itself
// via the clock, so return-by-value would leave dangling pointers).
var h: runner.Harness = undefined;
h.init(std.testing.allocator, .{});
defer h.deinit();

pub const Args = struct {
    plug: Memory,
    plug_id: []const u8,
};

pub fn runForPlug(args: Args) !void {
    var h = runner.Harness.init(std.testing.allocator, .{});
    defer h.deinit();

    // Invariant: append → read returns the same entry.
    try args.plug.vtable.append(args.plug.ctx, &h.ctx, "session-1", .{...});
    const entries = try args.plug.vtable.read(args.plug.ctx, &h.ctx, "session-1", .{});
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    // ... more invariants ...
}
```

## Consuming from a plug

Inside the plug's own test block:

```zig
// extensions/memory-jsonl/tests.zig
const contract = @import("../../tests/contract/memory/contract.zig");

test "memory-jsonl conforms to contract" {
    var plug = try buildJsonlPlug(std.testing.allocator);
    defer plug.deinit();

    try contract.runForPlug(.{
        .plug = plug.asMemory(),
        .plug_id = "memory-jsonl",
    });
}
```

## Rules

- Contract files have NO plug-specific knowledge; they test the
  capability contract, not the implementation.
- If an invariant only applies to a subset of plugs (e.g. durable
  storage), document that gate in the contract and make it opt-in
  via Args flags.
- Contract tests use `std.testing.allocator` (leak-detecting GPA).
- Contract tests DO NOT open sockets, spawn processes, or touch
  shared filesystem state outside the Harness arena.
