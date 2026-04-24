//! Telemetry — ops-facing spans and events.
//!
//! Every capability boundary emits telemetry: span_start at enter,
//! span_end at exit, events for noteworthy states. Distinct from
//! auditor, which emits compliance-grade records that survive
//! forget(purge). Telemetry can be dropped, sampled, rotated.
//!
//! Span model:
//!   - trace_id identifies a turn (16 bytes)
//!   - span_id identifies a slice within the turn (8 bytes)
//!   - parent_span_id chains spans into a tree
//!   - attrs are small key-value decorations
//!
//! Two shapes coexist:
//!   1. Telemetry vtable — the plug interface; impls are sinks
//!      (telemetry-stdout, telemetry-jsonl, telemetry-otel...)
//!   2. Spine helpers — newSpanId, nested() — tools for building the
//!      trace tree without touching the sink
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §infrastructure.telemetry

const std = @import("std");
const errors = @import("errors.zig");
const context_mod = @import("context");

const PlugError = errors.PlugError;
const Context = context_mod.Context;
const TraceId = context_mod.TraceId;
const SpanId = context_mod.SpanId;

pub const Status = enum { ok, err, cancelled };

pub const AttrValue = union(enum) {
    text: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    boolean: bool,
};

pub const KV = struct {
    key: []const u8,
    value: AttrValue,
};

/// Plug vtable. Each method takes a *const Context so subscribers
/// can see trace_id + parent_span_id + principal.
pub const Telemetry = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        span_start: *const fn (ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) PlugError!SpanId,
        span_end: *const fn (ptr: *anyopaque, ctx: *const Context, span: SpanId, status: Status) void,
        event: *const fn (ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) void,
        flush: *const fn (ptr: *anyopaque, ctx: *const Context) void,
    };

    pub fn spanStart(self: Telemetry, ctx: *const Context, name: []const u8, attrs: []const KV) PlugError!SpanId {
        return self.vtable.span_start(self.ptr, ctx, name, attrs);
    }

    pub fn spanEnd(self: Telemetry, ctx: *const Context, span: SpanId, status: Status) void {
        self.vtable.span_end(self.ptr, ctx, span, status);
    }

    pub fn event(self: Telemetry, ctx: *const Context, name: []const u8, attrs: []const KV) void {
        self.vtable.event(self.ptr, ctx, name, attrs);
    }

    pub fn flush(self: Telemetry, ctx: *const Context) void {
        self.vtable.flush(self.ptr, ctx);
    }
};

// --- spine helpers ---------------------------------------------------------

var span_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

/// Generate a fresh span id. Uses an atomic counter mixed with process
/// pid-ish entropy at startup. Non-cryptographic; good enough for
/// distinguishing spans within a process.
pub fn newSpanId() SpanId {
    const n = span_counter.fetchAdd(1, .monotonic);
    var out: SpanId = undefined;
    std.mem.writeInt(u64, out[0..], n, .little);
    return out;
}

/// Build a child Context where parent_span_id = provided span, trace_id
/// stays the same. Caller passes the returned ctx to inner plug calls.
pub fn nested(ctx: *const Context, new_parent: SpanId) Context {
    var out = ctx.*;
    out.parent_span_id = new_parent;
    return out;
}

// --- telemetry-stdout: first concrete sink --------------------------------

/// StdoutSink writes JSON-Lines to stdout. Minimal dep, no allocator
/// on the hot path beyond what `std.io` needs.
pub const StdoutSink = struct {
    pub fn telemetry(self: *StdoutSink) Telemetry {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn span_start_impl(ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) PlugError!SpanId {
        _ = ptr;
        _ = ctx;
        _ = attrs;
        // For now: just allocate an id; we don't serialize span_start
        // unconditionally (would double output per span). Serious
        // tracers emit start events; for CLI-friendly stdout we log
        // just end events with name + status.
        _ = name;
        return newSpanId();
    }

    fn span_end_impl(ptr: *anyopaque, ctx: *const Context, span: SpanId, status: Status) void {
        _ = ptr;
        _ = ctx;
        // Fire-and-forget stderr write; failures silently dropped to
        // avoid turning telemetry into a critical path.
        std.debug.print(
            "{{\"span\":\"{x}\",\"status\":\"{s}\"}}\n",
            .{ std.fmt.fmtSliceHexLower(&span), @tagName(status) },
        );
    }

    fn event_impl(ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) void {
        _ = ptr;
        _ = ctx;
        _ = attrs;
        std.debug.print("{{\"event\":\"{s}\"}}\n", .{name});
    }

    fn flush_impl(ptr: *anyopaque, ctx: *const Context) void {
        _ = ptr;
        _ = ctx;
        // std.debug.print is unbuffered; nothing to flush.
    }

    const vtable = Telemetry.VTable{
        .span_start = span_start_impl,
        .span_end = span_end_impl,
        .event = event_impl,
        .flush = flush_impl,
    };
};

// --- no-op sink for tests -------------------------------------------------

pub const NoopSink = struct {
    pub fn telemetry(self: *NoopSink) Telemetry {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn span_start_impl(ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) PlugError!SpanId {
        _ = ptr;
        _ = ctx;
        _ = name;
        _ = attrs;
        return newSpanId();
    }
    fn span_end_impl(ptr: *anyopaque, ctx: *const Context, span: SpanId, status: Status) void {
        _ = ptr;
        _ = ctx;
        _ = span;
        _ = status;
    }
    fn event_impl(ptr: *anyopaque, ctx: *const Context, name: []const u8, attrs: []const KV) void {
        _ = ptr;
        _ = ctx;
        _ = name;
        _ = attrs;
    }
    fn flush_impl(ptr: *anyopaque, ctx: *const Context) void {
        _ = ptr;
        _ = ctx;
    }

    const vtable = Telemetry.VTable{
        .span_start = span_start_impl,
        .span_end = span_end_impl,
        .event = event_impl,
        .flush = flush_impl,
    };
};

// --- contract -------------------------------------------------------------

/// Shared contract: every Telemetry impl must satisfy these.
pub fn runContract(t: Telemetry, ctx: *const Context) !void {
    const span = try t.spanStart(ctx, "test-contract", &.{});
    t.event(ctx, "test-event", &.{});
    t.spanEnd(ctx, span, .ok);
    t.flush(ctx);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const clock_mod = @import("clock");

fn mkTestContext(clk: *const clock_mod.Clock) Context {
    return .{
        .io = undefined,
        .alloc = testing.allocator,
        .clock = clk,
        .trace_id = std.mem.zeroes(TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "session:test",
        .origin_channel_id = null,
    };
}

test "newSpanId: produces non-zero ids" {
    const a = newSpanId();
    const b = newSpanId();
    // Both non-zero.
    try testing.expect(!std.mem.allEqual(u8, &a, 0));
    try testing.expect(!std.mem.allEqual(u8, &b, 0));
    // Distinct.
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "nested: inherits trace_id, sets parent_span_id" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    var parent = mkTestContext(&clk);
    const fake_trace = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    parent.trace_id = fake_trace;

    const new_span = newSpanId();
    const child = nested(&parent, new_span);

    try testing.expectEqual(parent.trace_id, child.trace_id);
    try testing.expect(child.parent_span_id != null);
    try testing.expectEqualSlices(u8, &new_span, &child.parent_span_id.?);
}

test "contract: NoopSink passes" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var sink = NoopSink{};
    try runContract(sink.telemetry(), &ctx);
}

test "NoopSink: spanStart returns distinct span ids" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = mkTestContext(&clk);

    var sink = NoopSink{};
    const t = sink.telemetry();

    const a = try t.spanStart(&ctx, "span-a", &.{});
    const b = try t.spanStart(&ctx, "span-b", &.{});
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
