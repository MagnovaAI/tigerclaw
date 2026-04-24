//! Contract-test runner.
//!
//! A contract test asserts invariants every plug of a given plugger
//! must satisfy. For example: every `memory` plug's `append` followed
//! by `read` must return the same entry; every `guardrails` plug's
//! `inspect` must be deterministic for fixed input.
//!
//! This file is shared scaffolding: a test helper that builds a fake
//! Context and runs a caller-supplied contract function against N
//! plug implementations. Plug authors add their plug id to the
//! `register.zig` list for the relevant plugger and the runner picks
//! them up.
//!
//! Usage (inside a plug's test block):
//!
//!   const runner = @import("../../tests/contract/runner.zig");
//!
//!   test "memory: conforms to contract" {
//!       try runner.runContract(
//!           memory_contract.runForPlug,
//!           .{ .plug = my_plug_impl, .plug_id = "memory-jsonl" },
//!       );
//!   }
//!
//! The actual contracts (one per plugger) land as separate files:
//!
//!   tests/contract/memory/contract.zig
//!   tests/contract/guardrails/contract.zig
//!   tests/contract/providers/contract.zig
//!   etc.
//!
//! Each contract file re-exports a `runForPlug(args)` function that
//! takes whatever plug reference its plugger expects.

const std = @import("std");
const clock_mod = @import("clock");
const context_mod = @import("context");
const errors = @import("errors.zig");

const Context = context_mod.Context;
const PlugError = errors.PlugError;

/// Scaffold that every contract test builds on top of. Owns a
/// FixedClock, an arena allocator, and the Context assembly. Caller
/// gets a fully-formed `*const Context` to pass into plug vtables.
pub const Harness = struct {
    clock_state: clock_mod.FixedClock,
    clock_iface: clock_mod.Clock,
    arena: std.heap.ArenaAllocator,
    ctx: Context,

    /// Initialize in place. Caller supplies the slot; we fill it.
    /// This is required because Context holds a pointer back into
    /// Harness's own fields (clock). Return-by-value would leave the
    /// pointer dangling inside the caller's copy.
    pub fn init(self: *Harness, gpa: std.mem.Allocator, opts: HarnessOpts) void {
        self.clock_state = .{ .value_ns = opts.clock_ns };
        self.arena = std.heap.ArenaAllocator.init(gpa);
        self.clock_iface = self.clock_state.clock();
        self.ctx = .{
            .io = undefined, // only wire when a contract needs syscalls
            .alloc = self.arena.allocator(),
            .clock = &self.clock_iface,
            .trace_id = std.mem.zeroes(context_mod.TraceId),
            .parent_span_id = null,
            .deadline_ms = opts.deadline_ms,
            .budget = null,
            .principal = opts.principal,
            .session_id = opts.session_id,
            .origin_channel_id = opts.origin_channel_id,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    pub fn advanceClockMs(self: *Harness, ms: i64) void {
        self.clock_state.value_ns += @as(i128, ms) * std.time.ns_per_ms;
    }
};

pub const HarnessOpts = struct {
    clock_ns: i128 = 0,
    deadline_ms: ?i64 = null,
    principal: []const u8 = "user:contract-test",
    session_id: []const u8 = "session:contract-test",
    origin_channel_id: ?[]const u8 = "chan-test-fake:local",
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Harness: builds a usable Context" {
    var h: Harness = undefined;
    h.init(testing.allocator, .{});
    defer h.deinit();

    try testing.expectEqualStrings("user:contract-test", h.ctx.principal);
    try testing.expectEqualStrings("session:contract-test", h.ctx.session_id);
    try testing.expectEqual(@as(?i64, null), h.ctx.deadline_ms);
    try testing.expectEqual(@as(i128, 0), h.ctx.clock.nowNs());
}

test "Harness: advanceClockMs moves the clock forward" {
    var h: Harness = undefined;
    h.init(testing.allocator, .{});
    defer h.deinit();

    h.advanceClockMs(250);
    try testing.expectEqual(@as(i128, 250 * std.time.ns_per_ms), h.ctx.clock.nowNs());
}

test "Harness: deadline flows into Context" {
    var h: Harness = undefined;
    h.init(testing.allocator, .{ .deadline_ms = 5000 });
    defer h.deinit();
    try testing.expectEqual(@as(?i64, 5000), h.ctx.deadline_ms);
}

test "Harness: custom principal/session/channel ids" {
    var h: Harness = undefined;
    h.init(testing.allocator, .{
        .principal = "agent:reviewer-01",
        .session_id = "session:pr-42",
        .origin_channel_id = "chan-collab-stdio:sub-1",
    });
    defer h.deinit();

    try testing.expectEqualStrings("agent:reviewer-01", h.ctx.principal);
    try testing.expectEqualStrings("session:pr-42", h.ctx.session_id);
    try testing.expect(h.ctx.origin_channel_id != null);
    try testing.expectEqualStrings("chan-collab-stdio:sub-1", h.ctx.origin_channel_id.?);
}

test "Harness: arena allocator survives until deinit" {
    var h: Harness = undefined;
    h.init(testing.allocator, .{});
    defer h.deinit();

    const bytes = try h.ctx.alloc.alloc(u8, 64);
    // Not freed explicitly — arena deinit takes care of it.
    @memset(bytes, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), bytes[0]);
}
