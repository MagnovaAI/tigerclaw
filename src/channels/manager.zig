//! Channel manager — owns the per-channel receive threads and the
//! shared dispatch queue. Lifecycle: register one or more `Channel`
//! values via `add`, then `start` spawns one thread per channel that
//! drives the channel's receive loop and pushes messages into the
//! dispatch FIFO. `stop` flips the cancel flag, waits for each
//! thread to drain its current receive call, and joins.
//!
//! ## Threading model
//!
//! - One thread per `Channel` value.
//! - All threads enqueue into the shared `Dispatch` instance.
//! - A single dispatch worker (caller's responsibility — the manager
//!   does not spawn it) calls `dequeue` and routes messages to the
//!   agent runner.
//! - The cancel flag is `std.atomic.Value(bool)`; `stop` sets it
//!   with `.release`; threads observe with `.acquire` on each
//!   iteration so any message already enqueued before cancellation
//!   is still visible downstream.
//!
//! The manager does NOT own the `Channel` values or the `Dispatch` —
//! they are all references. The caller manages their lifetimes.

const std = @import("std");

const spec = @import("channels_spec");
const dispatch_mod = @import("dispatch.zig");

pub const AddError = error{ OutOfMemory, DuplicateBinding };
pub const StartError = std.Thread.SpawnError || error{OutOfMemory};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dispatch: *dispatch_mod.Dispatch,
    entries: std.array_list.Aligned(*ChannelEntry, null) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Upper bound on the number of messages a receive thread pulls
    /// out of the channel per call before pushing the batch into
    /// the dispatch queue. Used as the allocation size for the
    /// per-thread scratch buffer.
    batch_size: usize = 16,
    /// How long a receive thread sleeps after the channel reports
    /// `Unauthorized` or `TransportFailure` before it tries again.
    /// Tests override this to keep wall-clock costs trivial.
    retry_backoff_ns: u64 = 500 * std.time.ns_per_ms,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        dispatch: *dispatch_mod.Dispatch,
    ) Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .dispatch = dispatch,
        };
    }

    pub fn deinit(self: *Manager) void {
        // Best-effort shutdown in case the caller forgot to call
        // `stop` before `deinit`; joining avoids leaking live
        // threads that reference this manager's memory.
        self.stop();
        for (self.entries.items) |entry| self.allocator.destroy(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Register a channel on behalf of a named agent. The tuple
    /// `(agent_name, channel.id())` uniquely identifies a binding — a
    /// second `add` with the same tuple returns `DuplicateBinding`.
    /// Multiple agents MAY share the same `ChannelId` kind; each gets
    /// its own receive thread and its own outbox partition.
    ///
    /// `agent_name` is borrowed; the caller keeps it alive for the
    /// lifetime of the manager.
    pub fn add(
        self: *Manager,
        agent_name: []const u8,
        channel: spec.Channel,
    ) AddError!void {
        // Dedup on (agent_name, channel_id). Linear scan is fine —
        // v0.1.0 fans out to a handful of agents.
        const cid = channel.id();
        for (self.entries.items) |e| {
            if (e.channel.id() == cid and std.mem.eql(u8, e.agent_name, agent_name)) {
                return error.DuplicateBinding;
            }
        }

        const entry = self.allocator.create(ChannelEntry) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .agent_name = agent_name, .channel = channel };
        self.entries.append(self.allocator, entry) catch return error.OutOfMemory;
    }

    /// Look up a previously-added channel by (agent_name, channel_id).
    /// Returns null if nothing matches. The returned handle remains
    /// valid until `deinit` — callers must not retain it across a
    /// manager restart.
    pub fn get(
        self: *const Manager,
        agent_name: []const u8,
        channel_id: spec.ChannelId,
    ) ?spec.Channel {
        for (self.entries.items) |e| {
            if (e.channel.id() == channel_id and std.mem.eql(u8, e.agent_name, agent_name)) {
                return e.channel;
            }
        }
        return null;
    }

    /// Spawn one receive thread per registered channel. The cancel
    /// flag is cleared before spawn so a manager that previously
    /// ran `stop` can be started again. Already-started channels
    /// are left alone — `start` is a no-op for entries that still
    /// hold a live thread handle.
    pub fn start(self: *Manager) StartError!void {
        self.cancel.store(false, .release);
        for (self.entries.items) |entry| {
            if (entry.thread != null) continue;
            entry.thread = try std.Thread.spawn(.{}, receiveLoopWrapper, .{ self, entry });
        }
    }

    /// Flip the cancel flag and join every channel thread. Safe to
    /// call without a prior `start`; in that case every entry's
    /// thread handle is already null and the function is a no-op
    /// past the flag flip.
    pub fn stop(self: *Manager) void {
        self.cancel.store(true, .release);
        for (self.entries.items) |entry| {
            if (entry.thread) |t| {
                t.join();
                entry.thread = null;
            }
        }
    }
};

const ChannelEntry = struct {
    /// Borrowed agent name, unique within this manager together with
    /// `channel.id()`. Enables multi-agent fan-out on a single daemon.
    agent_name: []const u8,
    channel: spec.Channel,
    thread: ?std.Thread = null,
};

fn receiveLoopWrapper(self: *Manager, entry: *ChannelEntry) void {
    receiveLoop(self, entry);
}

fn receiveLoop(self: *Manager, entry: *ChannelEntry) void {
    // `batch_size` is runtime-known, so the per-thread scratch
    // buffer has to be heap-allocated. One allocation per thread
    // for its whole lifetime — the hot path never allocates.
    const buf = self.allocator.alloc(spec.InboundMessage, self.batch_size) catch return;
    defer self.allocator.free(buf);

    while (!self.cancel.load(.acquire)) {
        const n = entry.channel.receive(buf, &self.cancel) catch |err| switch (err) {
            error.Unauthorized, error.TransportFailure => {
                // Sleep cancellably so `stop` still unsticks us
                // even when the upstream is in a sustained error
                // state.
                std.Io.sleep(
                    self.io,
                    std.Io.Duration.fromNanoseconds(@intCast(self.retry_backoff_ns)),
                    .awake,
                ) catch {};
                continue;
            },
        };
        if (n == 0) continue;
        const cid = entry.channel.id();
        for (buf[0..n]) |raw| {
            // Stamp routing fields before the message leaves the
            // receive thread. The channel adapter doesn't know which
            // agent it's bound to — only the manager does — so we
            // add agent_name here. channel_id is set from the vtable
            // so the dispatch worker doesn't have to re-query.
            var msg = raw;
            msg.channel_id = cid;
            msg.agent_name = entry.agent_name;
            _ = self.dispatch.enqueue(msg);
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Fake channel used across the test block. Deliberately local to
/// the file so we do not pull a test helper out of the production
/// surface.
const FakeChannel = struct {
    id_val: spec.ChannelId = .telegram,
    remaining: std.atomic.Value(u32),
    fail_count: std.atomic.Value(u32) = .init(0),
    ms_prefix: []const u8 = "m",

    fn make(remaining: u32) FakeChannel {
        return .{ .remaining = .init(remaining) };
    }

    fn channel(self: *FakeChannel) spec.Channel {
        return .{ .ptr = self, .vtable = &vt };
    }

    fn idFn(ptr: *anyopaque) spec.ChannelId {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        return self.id_val;
    }

    fn sendFn(_: *anyopaque, _: spec.OutboundMessage) spec.SendError!void {}

    fn receiveFn(
        ptr: *anyopaque,
        buf: []spec.InboundMessage,
        cancel: *const std.atomic.Value(bool),
    ) spec.ReceiveError!usize {
        const self: *FakeChannel = @ptrCast(@alignCast(ptr));
        if (cancel.load(.acquire)) return 0;

        if (self.fail_count.load(.acquire) > 0) {
            _ = self.fail_count.fetchSub(1, .acq_rel);
            return error.TransportFailure;
        }

        const r = self.remaining.load(.acquire);
        if (r > 0) {
            _ = self.remaining.fetchSub(1, .acq_rel);
            if (buf.len == 0) return 0;
            buf[0] = .{
                .upstream_id = r,
                .conversation_key = "c1",
                .sender_id = "u1",
                .text = self.ms_prefix,
            };
            return 1;
        }

        // Out of canned messages: yield so we don't pin a CPU while
        // the test waits for `stop` to flip the cancel flag.
        std.Thread.yield() catch {};
        return 0;
    }

    fn deinitFn(_: *anyopaque) void {}

    const vt: spec.Channel.VTable = .{
        .id = idFn,
        .send = sendFn,
        .receive = receiveFn,
        .deinit = deinitFn,
    };
};

test "start -> one message -> stop joins cleanly" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();
    mgr.retry_backoff_ns = 1 * std.time.ns_per_ms;

    var fake = FakeChannel.make(1);
    try mgr.add("agent-a", fake.channel());
    try mgr.start();

    var cancel = std.atomic.Value(bool).init(false);
    const msg = dispatch.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u64, 1), msg.upstream_id);

    mgr.stop();
}

test "stop without prior start is a no-op" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    var fake = FakeChannel.make(0);
    try mgr.add("agent-a", fake.channel());
    mgr.stop();
}

test "start can run twice with a stop in between" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 16);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();
    mgr.retry_backoff_ns = 1 * std.time.ns_per_ms;

    var fake = FakeChannel.make(1);
    try mgr.add("agent-a", fake.channel());

    try mgr.start();
    var cancel = std.atomic.Value(bool).init(false);
    _ = dispatch.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    mgr.stop();

    // Reload the fake with a second round of canned messages and
    // start again. The cancel flag must have been cleared by
    // `start` for the thread to observe the new work.
    fake.remaining.store(1, .release);
    try mgr.start();
    _ = dispatch.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    mgr.stop();
}

test "TransportFailure backs off then delivers" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 8);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();
    mgr.retry_backoff_ns = 1 * std.time.ns_per_ms;

    var fake = FakeChannel.make(1);
    fake.fail_count.store(3, .release);
    try mgr.add("agent-a", fake.channel());
    try mgr.start();

    var cancel = std.atomic.Value(bool).init(false);
    const msg = dispatch.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u64, 1), msg.upstream_id);
    try testing.expectEqual(@as(u32, 0), fake.fail_count.load(.acquire));

    mgr.stop();
}

test "two channels: both threads enqueue" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 32);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();
    mgr.retry_backoff_ns = 1 * std.time.ns_per_ms;

    var a = FakeChannel.make(5);
    var b = FakeChannel.make(3);
    try mgr.add("agent-a", a.channel());
    try mgr.add("agent-b", b.channel());
    try mgr.start();

    var cancel = std.atomic.Value(bool).init(false);
    var got: u32 = 0;
    while (got < 8) : (got += 1) {
        _ = dispatch.dequeue(&cancel) orelse return error.TestUnexpectedNull;
    }

    mgr.stop();
    try testing.expectEqual(@as(u64, 8), dispatch.stats().drained);
}

test "add: same (agent, channel_id) twice returns DuplicateBinding" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 4);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    var a = FakeChannel.make(0);
    var b = FakeChannel.make(0);
    try mgr.add("agent-a", a.channel());
    try testing.expectError(error.DuplicateBinding, mgr.add("agent-a", b.channel()));
}

test "get: returns the channel bound for (agent, channel_id)" {
    var dispatch = try dispatch_mod.Dispatch.init(testing.allocator, 4);
    defer dispatch.deinit();

    var mgr = Manager.init(testing.allocator, testing.io, &dispatch);
    defer mgr.deinit();

    var a = FakeChannel.make(0);
    var b = FakeChannel.make(0);
    try mgr.add("agent-a", a.channel());
    try mgr.add("agent-b", b.channel());

    try testing.expect(mgr.get("agent-a", .telegram) != null);
    try testing.expect(mgr.get("agent-b", .telegram) != null);
    try testing.expect(mgr.get("agent-c", .telegram) == null);
}
