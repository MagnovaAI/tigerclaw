//! Request-scoped Context.
//!
//! Every plug vtable method takes `*const Context` as its first
//! argument. Context bundles the things a plug needs to do its job
//! without depending on globals or cross-subsystem imports:
//!
//!   - io        process I/O abstraction (Zig stdlib)
//!   - alloc     per-request arena allocator (cheap to reset at turn end)
//!   - clock     injectable time source (tests wire a fake)
//!   - trace_id  stable 16-byte id that ties all spans of one turn
//!   - deadline  optional wall-clock cutoff for the whole operation
//!   - budget    optional meter handle (forward-declared; filled Phase 1)
//!   - principal who caused this turn (user id, peer id, scheduler job)
//!   - session_id conversation/session identifier
//!   - origin_channel_id reply routing pin for reactive turns
//!
//! Context is immutable after construction. A `child()` helper creates
//! a sub-context with a scoped allocator (for tool-call scope) or
//! different deadline (nested deadlines). `deadlineReached()` checks
//! expiry without mutating state.
//!
//! Budget (Meter) is forward-declared as an opaque pointer type; the
//! concrete vtable lands when the meter plugger is wired (Phase 1).
//!
//! Spec: docs/spec/agent-architecture-v3.yaml §architecture.context-object

const std = @import("std");
const clock_mod = @import("clock.zig");

/// Forward-declared meter handle. The real vtable lands in Phase 1 when
/// the meter plugger is introduced. Plugs that want to consult the
/// meter accept a `?*const Meter` and call through the opaque pointer
/// once the vtable is in place.
pub const Meter = opaque {};

/// 16-byte trace id (ULID-ish shape; actual generation decided per
/// request). Zero-valued is treated as unset for the root-level call.
pub const TraceId = [16]u8;

/// 8-byte span id; parent_span_id is null at the root of a trace.
pub const SpanId = [8]u8;

/// Immutable per-request bundle. Every vtable method takes `*const
/// Context` as its first parameter.
pub const Context = struct {
    /// Process I/O abstraction; go through this for syscalls so tests
    /// can inject a fake Io.
    io: *std.Io,

    /// Per-request arena. Freed at turn end. Plugs allocate freely.
    alloc: std.mem.Allocator,

    /// Injectable time source. Use `clock.nowNs()` etc.
    clock: *const clock_mod.Clock,

    /// Stable 16-byte id tying every span of this turn together.
    trace_id: TraceId,

    /// Parent span id; null at the root of a trace.
    parent_span_id: ?SpanId,

    /// Wall-clock deadline for this operation. null means no deadline.
    /// Compared against `clock.nowNs()` converted to ms.
    deadline_ms: ?i64,

    /// Meter handle; budget reservations go through this once the
    /// meter plugger is wired (Phase 1). Forward-declared here.
    budget: ?*const Meter,

    /// Who caused this turn. Typed peer id as a canonical string for
    /// now ("user:omkar", "agent:reviewer-01", "discord_user:1234").
    /// Typed PeerId lands in Phase 0.5.
    principal: []const u8,

    /// Conversation/session identifier. Stable across the turn.
    session_id: []const u8,

    /// Origin channel id. For reactive turns this pins the reply
    /// destination; autonomous turns (wake-triggered) pick this from
    /// composition config. Null is allowed for purely internal turns.
    /// Typed ChannelId lands in Phase 0.5.
    origin_channel_id: ?[]const u8,

    /// Make a sub-context with a different allocator (typical use: a
    /// scoped arena for a single tool call). All other fields carry
    /// forward unchanged. Caller owns the returned value.
    pub fn child(self: *const Context, alloc: std.mem.Allocator) Context {
        return .{
            .io = self.io,
            .alloc = alloc,
            .clock = self.clock,
            .trace_id = self.trace_id,
            .parent_span_id = self.parent_span_id,
            .deadline_ms = self.deadline_ms,
            .budget = self.budget,
            .principal = self.principal,
            .session_id = self.session_id,
            .origin_channel_id = self.origin_channel_id,
        };
    }

    /// Make a sub-context that also tightens the deadline. Useful for
    /// inner operations whose deadline must not exceed the caller's.
    /// `deadline_ms_override` may be null (clears), equal to parent, or
    /// shorter. Callers may not widen a deadline — that returns the
    /// parent deadline unchanged.
    pub fn childWithDeadline(
        self: *const Context,
        alloc: std.mem.Allocator,
        deadline_ms_override: ?i64,
    ) Context {
        var out = self.child(alloc);
        // Pick the tighter deadline.
        if (deadline_ms_override) |new_dl| {
            if (self.deadline_ms) |parent_dl| {
                out.deadline_ms = @min(parent_dl, new_dl);
            } else {
                out.deadline_ms = new_dl;
            }
        }
        return out;
    }

    /// Returns true iff the deadline is set and has passed.
    pub fn deadlineReached(self: *const Context) bool {
        const dl = self.deadline_ms orelse return false;
        const now_ns = self.clock.nowNs();
        const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
        return now_ms >= dl;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeTestContext(clock: *const clock_mod.Clock, alloc: std.mem.Allocator) Context {
    return .{
        .io = undefined, // tests that need io supply it themselves
        .alloc = alloc,
        .clock = clock,
        .trace_id = std.mem.zeroes(TraceId),
        .parent_span_id = null,
        .deadline_ms = null,
        .budget = null,
        .principal = "user:test",
        .session_id = "session:test",
        .origin_channel_id = "channel-cli:local",
    };
}

test "child preserves all fields except allocator" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();

    const parent = makeTestContext(&clk, testing.allocator);

    // Child with a different allocator (conceptually; same alloc here).
    const child = parent.child(testing.allocator);

    try testing.expectEqual(parent.clock, child.clock);
    try testing.expectEqual(parent.trace_id, child.trace_id);
    try testing.expectEqual(parent.parent_span_id, child.parent_span_id);
    try testing.expectEqual(parent.deadline_ms, child.deadline_ms);
    try testing.expectEqual(parent.budget, child.budget);
    try testing.expectEqualStrings(parent.principal, child.principal);
    try testing.expectEqualStrings(parent.session_id, child.session_id);
}

test "childWithDeadline: tightens when shorter" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();

    var parent = makeTestContext(&clk, testing.allocator);
    parent.deadline_ms = 1000;

    const child = parent.childWithDeadline(testing.allocator, 500);
    try testing.expectEqual(@as(?i64, 500), child.deadline_ms);
}

test "childWithDeadline: keeps parent when new deadline is looser" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();

    var parent = makeTestContext(&clk, testing.allocator);
    parent.deadline_ms = 500;

    const child = parent.childWithDeadline(testing.allocator, 1000);
    try testing.expectEqual(@as(?i64, 500), child.deadline_ms);
}

test "childWithDeadline: applies when parent has no deadline" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();

    const parent = makeTestContext(&clk, testing.allocator);
    try testing.expectEqual(@as(?i64, null), parent.deadline_ms);

    const child = parent.childWithDeadline(testing.allocator, 250);
    try testing.expectEqual(@as(?i64, 250), child.deadline_ms);
}

test "deadlineReached: false when no deadline set" {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = makeTestContext(&clk, testing.allocator);
    try testing.expect(!ctx.deadlineReached());
}

test "deadlineReached: true when clock is past deadline" {
    // Clock reports 2_000_000_000 ns = 2000 ms
    var fixed = clock_mod.FixedClock{ .value_ns = 2_000_000_000 };
    const clk = fixed.clock();

    var ctx = makeTestContext(&clk, testing.allocator);
    ctx.deadline_ms = 1000;

    try testing.expect(ctx.deadlineReached());
}

test "deadlineReached: false when clock is before deadline" {
    var fixed = clock_mod.FixedClock{ .value_ns = 500 * std.time.ns_per_ms };
    const clk = fixed.clock();

    var ctx = makeTestContext(&clk, testing.allocator);
    ctx.deadline_ms = 1000;

    try testing.expect(!ctx.deadlineReached());
}
