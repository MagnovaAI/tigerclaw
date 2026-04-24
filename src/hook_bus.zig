//! Named hook bus for cross-cutting concerns.
//!
//! HookBus is a priority-ordered synchronous event dispatcher. Plugs
//! (or any subsystem) subscribe handlers to named HookEvents; the
//! turn loop and other orchestrators fire those events at well-known
//! phase points.
//!
//! Key design decisions:
//!   - Synchronous by default. Fire() runs every subscriber inline
//!     before returning. Async variants may come later if needed.
//!   - Priority-ordered. Smaller priority numbers run first; ties
//!     broken by subscription order.
//!   - Handler signature is uniform: takes the Context and an opaque
//!     payload pointer; returns PlugError!void.
//!   - Unsubscribe is supported but rare: subscriptions typically live
//!     for the entire process lifetime.
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.hook-bus

const std = @import("std");
const context_mod = @import("context");
const errors = @import("errors.zig");

const Context = context_mod.Context;
const PlugError = errors.PlugError;

/// Named hook events. Append-only; existing values never change.
/// Values 0-15 are reserved for core phase points; plug-specific
/// events go at 16+.
pub const HookEvent = enum(u16) {
    before_sense = 0,
    before_reason = 1,
    before_dispatch = 2, // before any tool_call fires
    before_reply = 3,
    before_converse = 4,
    on_tool_call = 5,
    on_gate_defer = 6,
    on_gate_deferred_resolved = 7,
    on_config_reload = 8,
    on_shutdown = 9,

    _, // reserved for future events
};

/// Handler signature. Handlers MUST handle payload being a null-shaped
/// opaque pointer — callers may fire with no payload.
pub const HookHandler = *const fn (ctx: *const Context, payload: ?*anyopaque) PlugError!void;

/// Opaque handle returned by subscribe(); pass back to unsubscribe().
pub const Subscription = struct {
    event: HookEvent,
    id: u32, // stable across the bus lifetime
};

const SubscriberRecord = struct {
    id: u32,
    priority: i32,
    seq: u32, // for stable tie-breaking
    handler: HookHandler,
};

pub const HookBus = struct {
    alloc: std.mem.Allocator,
    // One ArrayList per event. Grown lazily; most events have no subs.
    // Keyed by @intFromEnum(HookEvent). Allocated on first subscribe.
    subs: std.AutoHashMapUnmanaged(u16, std.ArrayList(SubscriberRecord)) = .empty,
    next_id: u32 = 0,
    next_seq: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) HookBus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *HookBus) void {
        var it = self.subs.valueIterator();
        while (it.next()) |list_ptr| {
            list_ptr.deinit(self.alloc);
        }
        self.subs.deinit(self.alloc);
    }

    /// Subscribe `handler` to `event` with the given priority. Smaller
    /// priorities run first. Ties broken by subscription order.
    pub fn subscribe(
        self: *HookBus,
        event: HookEvent,
        handler: HookHandler,
        priority: i32,
    ) !Subscription {
        const key = @intFromEnum(event);
        const gop = try self.subs.getOrPut(self.alloc, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;

        const id = self.next_id;
        self.next_id += 1;
        const seq = self.next_seq;
        self.next_seq += 1;

        try gop.value_ptr.append(self.alloc, .{
            .id = id,
            .priority = priority,
            .seq = seq,
            .handler = handler,
        });

        // Keep the list sorted by (priority asc, seq asc) so fire() is
        // a straight walk.
        std.mem.sort(SubscriberRecord, gop.value_ptr.items, {}, struct {
            fn lt(_: void, a: SubscriberRecord, b: SubscriberRecord) bool {
                if (a.priority != b.priority) return a.priority < b.priority;
                return a.seq < b.seq;
            }
        }.lt);

        return .{ .event = event, .id = id };
    }

    /// Remove the given subscription. Safe to call mid-fire: the
    /// current invocation finishes; subsequent fires won't see the
    /// removed handler.
    pub fn unsubscribe(self: *HookBus, sub: Subscription) void {
        const key = @intFromEnum(sub.event);
        const list_ptr = self.subs.getPtr(key) orelse return;
        var i: usize = 0;
        while (i < list_ptr.items.len) : (i += 1) {
            if (list_ptr.items[i].id == sub.id) {
                _ = list_ptr.orderedRemove(i);
                return;
            }
        }
    }

    /// Fire an event synchronously. Every handler runs in priority
    /// order; if any returns an error, later handlers do NOT run and
    /// the error propagates to the caller.
    pub fn fire(
        self: *HookBus,
        ctx: *const Context,
        event: HookEvent,
        payload: ?*anyopaque,
    ) PlugError!void {
        const key = @intFromEnum(event);
        const list_ptr = self.subs.getPtr(key) orelse return;
        for (list_ptr.items) |s| {
            try s.handler(ctx, payload);
        }
    }

    /// Count of subscribers for `event`. Useful for tests.
    pub fn subscriberCount(self: *HookBus, event: HookEvent) usize {
        const key = @intFromEnum(event);
        const list_ptr = self.subs.getPtr(key) orelse return 0;
        return list_ptr.items.len;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock");

fn mkTestContext(clk: *const clock_mod.Clock) Context {
    return .{
        .io = undefined,
        .alloc = testing.allocator,
        .clock = clk,
        .trace_id = std.mem.zeroes(context_mod.TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "session:test",
        .origin_channel_id = null,
    };
}

// Test-only recording sink. Handlers receive the ArrayList pointer as
// the payload and append a char to it. Lifetime owned by each test.
fn append_char(comptime c: u8) HookHandler {
    return struct {
        fn call(ctx: *const Context, payload: ?*anyopaque) PlugError!void {
            const log: *std.ArrayList(u8) = @ptrCast(@alignCast(payload orelse return));
            log.append(ctx.alloc, c) catch return error.Internal;
        }
    }.call;
}

const h_first = append_char('A');
const h_second = append_char('B');
const h_third = append_char('C');

fn h_fail(ctx: *const Context, payload: ?*anyopaque) PlugError!void {
    _ = ctx;
    _ = payload;
    return error.Refused;
}

test "subscribe + fire: single handler runs" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    _ = try bus.subscribe(.before_reason, h_first, 0);

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try bus.fire(&ctx, .before_reason, @ptrCast(&log));
    try testing.expectEqualStrings("A", log.items);
}

test "priority: smaller priority runs first" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    _ = try bus.subscribe(.before_reply, h_third, 10); // runs last
    _ = try bus.subscribe(.before_reply, h_first, 0); //  runs first
    _ = try bus.subscribe(.before_reply, h_second, 5); // runs middle

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try bus.fire(&ctx, .before_reply, @ptrCast(&log));
    try testing.expectEqualStrings("ABC", log.items);
}

test "priority ties broken by subscription order" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    _ = try bus.subscribe(.on_tool_call, h_first, 5);
    _ = try bus.subscribe(.on_tool_call, h_second, 5);
    _ = try bus.subscribe(.on_tool_call, h_third, 5);

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try bus.fire(&ctx, .on_tool_call, @ptrCast(&log));
    try testing.expectEqualStrings("ABC", log.items);
}

test "error in handler halts firing chain" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    _ = try bus.subscribe(.before_dispatch, h_first, 0);
    _ = try bus.subscribe(.before_dispatch, h_fail, 1);
    _ = try bus.subscribe(.before_dispatch, h_third, 2);

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try testing.expectError(error.Refused, bus.fire(&ctx, .before_dispatch, @ptrCast(&log)));
    // A ran, fail ran + errored, C did NOT run.
    try testing.expectEqualStrings("A", log.items);
}

test "unsubscribe removes handler" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);

    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    const sub = try bus.subscribe(.on_shutdown, h_first, 0);
    _ = try bus.subscribe(.on_shutdown, h_second, 1);

    try testing.expectEqual(@as(usize, 2), bus.subscriberCount(.on_shutdown));
    bus.unsubscribe(sub);
    try testing.expectEqual(@as(usize, 1), bus.subscriberCount(.on_shutdown));

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try bus.fire(&ctx, .on_shutdown, @ptrCast(&log));
    try testing.expectEqualStrings("B", log.items);
}

test "fire with no subscribers is a no-op" {
    var bus = HookBus.init(testing.allocator);
    defer bus.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    try bus.fire(&ctx, .before_converse, null);
    try testing.expectEqual(@as(usize, 0), bus.subscriberCount(.before_converse));
}
