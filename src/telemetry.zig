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
const builtin = @import("builtin");
const errors = @import("errors");
const context_mod = @import("context");

const PlugError = errors.PlugError;
const Context = context_mod.Context;
const TraceId = context_mod.TraceId;
const SpanId = context_mod.SpanId;

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;

pub const Status = enum { ok, err, cancelled };

pub const ResourceSample = struct {
    cpu_user_us: u64,
    cpu_system_us: u64,
    cpu_total_us: u64,
    cpu_percent_x100: u64,
    cpu_logical_cores: u32,
    app_ram_used_bytes: u64,
    max_rss_bytes: u64,
    system_ram_total_bytes: u64,

    pub fn appRamUsedPctX100(self: ResourceSample) u64 {
        if (self.system_ram_total_bytes == 0) return 0;
        return @divTrunc(self.app_ram_used_bytes * 10_000, self.system_ram_total_bytes);
    }

    pub fn appRamAvailableBytes(self: ResourceSample) u64 {
        return self.system_ram_total_bytes -| self.app_ram_used_bytes;
    }
};

pub fn sampleResources() ResourceSample {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return emptyResourceSample();
    }

    const sampled_ns = monotonicNowNs();
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const cpu_user_us = timevalMicros(usage.utime);
    const cpu_system_us = timevalMicros(usage.stime);
    const cpu_total_us = cpu_user_us + cpu_system_us;
    const cpu_logical_cores = logicalCpuCount();
    const max_rss_bytes = rssBytes(usage.maxrss);
    return .{
        .cpu_user_us = cpu_user_us,
        .cpu_system_us = cpu_system_us,
        .cpu_total_us = cpu_total_us,
        .cpu_percent_x100 = cpuPercentX100(sampled_ns, cpu_total_us, cpu_logical_cores),
        .cpu_logical_cores = cpu_logical_cores,
        .app_ram_used_bytes = currentResidentBytes() orelse max_rss_bytes,
        .max_rss_bytes = max_rss_bytes,
        .system_ram_total_bytes = systemRamTotalBytes(),
    };
}

fn emptyResourceSample() ResourceSample {
    return .{
        .cpu_user_us = 0,
        .cpu_system_us = 0,
        .cpu_total_us = 0,
        .cpu_percent_x100 = 0,
        .cpu_logical_cores = 0,
        .app_ram_used_bytes = 0,
        .max_rss_bytes = 0,
        .system_ram_total_bytes = 0,
    };
}

fn timevalMicros(tv: std.c.timeval) u64 {
    const secs: u64 = @intCast(@max(tv.sec, 0));
    const usecs: u64 = @intCast(@max(tv.usec, 0));
    return secs * 1_000_000 + usecs;
}

fn rssBytes(maxrss: isize) u64 {
    const value: u64 = @intCast(@max(maxrss, 0));
    return switch (builtin.target.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => value,
        else => value * 1024,
    };
}

fn logicalCpuCount() u32 {
    const count = std.Thread.getCpuCount() catch return 0;
    return @intCast(@min(count, std.math.maxInt(u32)));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    if (ts.sec < 0 or ts.nsec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

var last_sample_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var last_sample_cpu_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn cpuPercentX100(sampled_ns: u64, cpu_total_us: u64, logical_cores: u32) u64 {
    if (sampled_ns == 0 or logical_cores == 0) return 0;

    const previous_ns = last_sample_ns.swap(sampled_ns, .monotonic);
    const previous_cpu_us = last_sample_cpu_us.swap(cpu_total_us, .monotonic);
    if (previous_ns == 0 or sampled_ns <= previous_ns or cpu_total_us < previous_cpu_us) return 0;

    const elapsed_us = @divTrunc(sampled_ns - previous_ns, std.time.ns_per_us);
    if (elapsed_us == 0) return 0;

    const cpu_delta_us = cpu_total_us - previous_cpu_us;
    const capacity_us = elapsed_us * logical_cores;
    if (capacity_us == 0) return 0;
    return @divTrunc(cpu_delta_us * 10_000, capacity_us);
}

fn systemRamTotalBytes() u64 {
    return std.process.totalSystemMemory() catch 0;
}

fn currentResidentBytes() ?u64 {
    return switch (builtin.target.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => currentResidentBytesDarwin(),
        else => null,
    };
}

fn currentResidentBytesDarwin() ?u64 {
    const PROC_PIDTASKINFO: c_int = 4;
    const ProcTaskInfo = extern struct {
        pti_virtual_size: u64,
        pti_resident_size: u64,
        pti_total_user: u64,
        pti_total_system: u64,
        pti_threads_user: u64,
        pti_threads_system: u64,
        pti_policy: i32,
        pti_faults: i32,
        pti_pageins: i32,
        pti_cow_faults: i32,
        pti_messages_sent: i32,
        pti_messages_received: i32,
        pti_syscalls_mach: i32,
        pti_syscalls_unix: i32,
        pti_csw: i32,
        pti_threadnum: i32,
        pti_numrunning: i32,
        pti_priority: i32,
    };
    var info: ProcTaskInfo = undefined;
    const got = proc_pidinfo(
        @intCast(std.c.getpid()),
        PROC_PIDTASKINFO,
        0,
        &info,
        @intCast(@sizeOf(ProcTaskInfo)),
    );
    if (got != @sizeOf(ProcTaskInfo)) return null;
    return info.pti_resident_size;
}

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

test "sampleResources: returns monotonic process counters" {
    const first = sampleResources();
    const second = sampleResources();

    try testing.expect(second.cpu_user_us >= first.cpu_user_us);
    try testing.expect(second.cpu_system_us >= first.cpu_system_us);
    try testing.expectEqual(second.cpu_user_us + second.cpu_system_us, second.cpu_total_us);
    try testing.expect(second.cpu_logical_cores > 0);
    try testing.expect(second.app_ram_used_bytes > 0);
    try testing.expect(second.system_ram_total_bytes >= second.app_ram_used_bytes);
    try testing.expect(second.max_rss_bytes >= first.max_rss_bytes);
}
