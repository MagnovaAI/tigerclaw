//! Integration tests for the diagnostics ring buffer.
//!
//! The buffer's value comes from three promises it makes to
//! consumers: chronological order survives wraparound, dropped
//! events are countable, and concurrent pushes from any thread
//! are safe. These tests lock those promises down through the
//! public library surface.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const diagnostics = tigerclaw.util.diagnostics;

test "diagnostics buffer: typical startup-metric sequence round-trips" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 8, null);
    defer b.deinit();

    _ = b.push(.info, "settings loaded");
    _ = b.push(.metric, "startup_ms=24");
    _ = b.push(.info, "sandbox=noop");
    _ = b.push(.metric, "first_turn_ms=124");

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);

    try testing.expectEqual(@as(usize, 4), snap.len);
    try testing.expectEqualStrings("settings loaded", snap[0].message());
    try testing.expectEqualStrings("first_turn_ms=124", snap[3].message());
    try testing.expectEqual(diagnostics.Kind.metric, snap[1].kind);
    try testing.expectEqual(diagnostics.Kind.metric, snap[3].kind);
}

test "diagnostics buffer: wraparound reports total vs retained counts" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 3, null);
    defer b.deinit();

    // Push six events into a 3-slot buffer; oldest three are
    // dropped. A UI can tell the user "3 events dropped" by
    // subtracting len from totalPushes.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "e{d}", .{i});
        _ = b.push(.info, s);
    }

    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expectEqual(@as(u64, 6), b.totalPushes());

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings("e3", snap[0].message());
    try testing.expectEqualStrings("e5", snap[2].message());
}

test "diagnostics buffer: warn and err kinds survive" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 4, null);
    defer b.deinit();

    _ = b.push(.warn, "provider fallback");
    _ = b.push(.err, "retry budget exhausted");

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expectEqual(diagnostics.Kind.warn, snap[0].kind);
    try testing.expectEqual(diagnostics.Kind.err, snap[1].kind);
}

test "diagnostics buffer: snapshotInto writes into a caller slice" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 4, null);
    defer b.deinit();

    _ = b.push(.info, "a");
    _ = b.push(.info, "b");

    var out: [4]diagnostics.Event = undefined;
    const n = b.snapshotInto(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", out[0].message());
    try testing.expectEqualStrings("b", out[1].message());
}

test "diagnostics buffer: long messages are truncated with original_len preserved" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 2, null);
    defer b.deinit();

    var giant: [4096]u8 = undefined;
    @memset(&giant, 'A');
    _ = b.push(.info, &giant);

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expect(snap[0].wasTruncated());
    try testing.expectEqual(diagnostics.max_message_bytes, snap[0].message().len);
    try testing.expectEqual(@as(u32, 4096), snap[0].original_len);
}

test "diagnostics buffer: concurrent pushes do not lose events" {
    // 12 threads × 250 pushes each into a large buffer. Total
    // pushes observed must equal 12 * 250; the buffer is bigger
    // than the workload so nothing wraps.
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 4096, null);
    defer b.deinit();

    const per_thread: u32 = 250;
    const thread_count: usize = 12;

    const Worker = struct {
        fn run(buf: *diagnostics.DiagnosticsBuffer, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) _ = buf.push(.metric, "tick");
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &b, per_thread });
    }
    for (threads) |t| t.join();

    try testing.expectEqual(
        @as(u64, @as(u64, thread_count) * per_thread),
        b.totalPushes(),
    );
    try testing.expectEqual(@as(usize, thread_count * per_thread), b.len());
}

test "diagnostics buffer: clear resets len but continues the seq stream" {
    var b = try diagnostics.DiagnosticsBuffer.init(testing.allocator, 4, null);
    defer b.deinit();

    _ = b.push(.info, "x");
    _ = b.push(.info, "y");
    b.clear();
    try testing.expectEqual(@as(usize, 0), b.len());

    const seq = b.push(.info, "z");
    try testing.expectEqual(@as(u64, 2), seq);

    const snap = try b.snapshot(testing.allocator);
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings("z", snap[0].message());
}
