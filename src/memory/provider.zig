//! Memory provider — agent-facing surface.
//!
//! `Provider` is the vtable the runner calls each turn: ask for
//! pre-turn context (`prefetch`), record the user/assistant pair
//! (`syncTurn`), and emit a system-prompt block (`systemPromptBlock`)
//! that is concatenated into the loop's system prompt.
//!
//! This is *not* the storage abstraction. `memory_spec.SessionStore`
//! owns bytes-on-disk; a `Provider` is built on top of one (or none,
//! for ephemeral providers) and translates the agent's intent into
//! store calls. Built-in (`builtin.zig`) wraps a SessionStore plus a
//! per-agent `MEMORY.md` file; external providers (one at a time, per
//! `manager.zig`) speak whatever protocol they like behind this same
//! vtable.
//!
//! Lifecycle: `initialize` once at runner start; `prefetch` and
//! `syncTurn` per turn; `shutdown` on teardown. Every method is
//! pointer-stable for the provider's lifetime.

const std = @import("std");

/// Closed error set. `BackendFailure` wraps every transport-level
/// failure from the underlying store; the runner logs the underlying
/// errno via the provider's own logger and returns a coarse code.
pub const MemoryError = error{
    OutOfMemory,
    BackendFailure,
    InvalidQuery,
};

/// Result of `prefetch`. `text` is borrowed from the provider and
/// valid until the next call on the same provider; the runner copies
/// what it needs before issuing the next call. Empty `text` means
/// "no context to inject."
pub const Prefetch = struct {
    text: []const u8,
};

/// One turn pair. Bodies are borrowed from the runner; the provider
/// copies whatever it persists.
pub const TurnPair = struct {
    user: []const u8,
    assistant: []const u8,
};

pub const VTable = struct {
    initialize: *const fn (ptr: *anyopaque) MemoryError!void,
    system_prompt_block: *const fn (ptr: *anyopaque) MemoryError![]const u8,
    prefetch: *const fn (ptr: *anyopaque, query: []const u8) MemoryError!Prefetch,
    sync_turn: *const fn (ptr: *anyopaque, pair: TurnPair) MemoryError!void,
    shutdown: *const fn (ptr: *anyopaque) void,
};

/// Stable identifier for the provider. Used by `manager.zig` to
/// enforce the "at most one external" rule and by logs to attribute
/// failures.
pub const Kind = enum { builtin, external };

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    kind: Kind,
    /// Stable name for logs. Borrowed; the provider owns it.
    name: []const u8,

    pub fn initialize(self: Provider) MemoryError!void {
        return self.vtable.initialize(self.ptr);
    }

    pub fn systemPromptBlock(self: Provider) MemoryError![]const u8 {
        return self.vtable.system_prompt_block(self.ptr);
    }

    pub fn prefetch(self: Provider, query: []const u8) MemoryError!Prefetch {
        return self.vtable.prefetch(self.ptr, query);
    }

    pub fn syncTurn(self: Provider, pair: TurnPair) MemoryError!void {
        return self.vtable.sync_turn(self.ptr, pair);
    }

    pub fn shutdown(self: Provider) void {
        self.vtable.shutdown(self.ptr);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    init_calls: u32 = 0,
    sys_calls: u32 = 0,
    prefetch_calls: u32 = 0,
    sync_calls: u32 = 0,
    shutdown_calls: u32 = 0,
    last_query: []const u8 = "",
    last_pair: ?TurnPair = null,
    canned_prefetch: []const u8 = "",
    canned_block: []const u8 = "",
    fail_initialize: bool = false,

    fn provider(self: *Recorder) Provider {
        return .{ .ptr = self, .vtable = &vt, .kind = .builtin, .name = "recorder" };
    }

    fn initFn(p: *anyopaque) MemoryError!void {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.init_calls += 1;
        if (self.fail_initialize) return MemoryError.BackendFailure;
    }

    fn sysFn(p: *anyopaque) MemoryError![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.sys_calls += 1;
        return self.canned_block;
    }

    fn prefetchFn(p: *anyopaque, query: []const u8) MemoryError!Prefetch {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.prefetch_calls += 1;
        self.last_query = query;
        return .{ .text = self.canned_prefetch };
    }

    fn syncFn(p: *anyopaque, pair: TurnPair) MemoryError!void {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.sync_calls += 1;
        self.last_pair = pair;
    }

    fn shutdownFn(p: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(p));
        self.shutdown_calls += 1;
    }

    const vt: VTable = .{
        .initialize = initFn,
        .system_prompt_block = sysFn,
        .prefetch = prefetchFn,
        .sync_turn = syncFn,
        .shutdown = shutdownFn,
    };
};

test "Provider: round-trip through every vtable method" {
    var r: Recorder = .{ .canned_prefetch = "ctx", .canned_block = "block" };
    const p = r.provider();

    try p.initialize();
    const block = try p.systemPromptBlock();
    const got = try p.prefetch("question");
    try p.syncTurn(.{ .user = "u", .assistant = "a" });
    p.shutdown();

    try testing.expectEqualStrings("block", block);
    try testing.expectEqualStrings("ctx", got.text);
    try testing.expectEqualStrings("question", r.last_query);
    try testing.expectEqualStrings("u", r.last_pair.?.user);
    try testing.expectEqualStrings("a", r.last_pair.?.assistant);
    try testing.expectEqual(@as(u32, 1), r.init_calls);
    try testing.expectEqual(@as(u32, 1), r.shutdown_calls);
}

test "Provider: initialize propagates BackendFailure" {
    var r: Recorder = .{ .fail_initialize = true };
    const p = r.provider();
    try testing.expectError(MemoryError.BackendFailure, p.initialize());
}
