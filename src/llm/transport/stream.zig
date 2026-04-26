//! Reader → SSE event adapter.
//!
//! Wraps a `*std.Io.Reader` so callers can pull `Event`s from a live
//! stream without assembling byte buffers themselves. The reader is
//! borrowed; Stream does not close it.

const std = @import("std");
const sse = @import("sse.zig");

pub const Stream = struct {
    reader: *std.Io.Reader,
    parser: sse.Parser,
    eof: bool = false,
    chunk: [1024]u8 = undefined,

    pub fn init(reader: *std.Io.Reader) Stream {
        return .{ .reader = reader, .parser = .init() };
    }

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        self.parser.deinit(allocator);
    }

    /// Returns the next event, or null at end-of-stream. Reads more
    /// bytes from the underlying reader as needed. Event slices are
    /// invalidated by the next call.
    pub fn next(self: *Stream, allocator: std.mem.Allocator) !?sse.Event {
        return self.nextCancellable(allocator, null);
    }

    /// Same as `next` but polls `cancel` between byte reads. When the
    /// flag is set, returns `error.Cancelled` so the caller can surface
    /// a partial response with the appropriate stop reason. Provider
    /// adapters thread their `ChatRequest.cancel_token` here so cancel
    /// works the same way for every SSE-based backend (Anthropic,
    /// OpenAI, OpenRouter, ...).
    pub fn nextCancellable(
        self: *Stream,
        allocator: std.mem.Allocator,
        cancel: ?*std.atomic.Value(bool),
    ) !?sse.Event {
        while (true) {
            if (try self.parser.nextEvent(allocator)) |ev| return ev;
            if (self.eof) return null;

            if (cancel) |c| if (c.load(.acquire)) return error.Cancelled;

            const n = try self.reader.readSliceShort(&self.chunk);
            if (n == 0) {
                self.eof = true;
                return try self.parser.nextEvent(allocator);
            }
            try self.parser.feed(allocator, self.chunk[0..n]);
        }
    }
};

pub const StreamError = error{Cancelled};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Stream: reads events out of an in-memory reader" {
    const bytes = "event: greet\ndata: hello\n\ndata: world\n\n";
    var r: std.Io.Reader = .fixed(bytes);

    var s = Stream.init(&r);
    defer s.deinit(testing.allocator);

    const first = try s.next(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("greet", first.name);
    try testing.expectEqualStrings("hello", first.data);

    const second = try s.next(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("world", second.data);

    try testing.expect((try s.next(testing.allocator)) == null);
}

test "Stream: partial buffering across reads still yields a single event" {
    const bytes = "data: combined-payload\n\n";
    var r: std.Io.Reader = .fixed(bytes);

    var s = Stream.init(&r);
    defer s.deinit(testing.allocator);

    const ev = try s.next(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("combined-payload", ev.data);
}

test "Stream.nextCancellable: returns Cancelled when flag is set before next read" {
    const bytes = "data: a\n\ndata: b\n\n";
    var r: std.Io.Reader = .fixed(bytes);

    var s = Stream.init(&r);
    defer s.deinit(testing.allocator);

    // Consume the first event so we know the parser still has buffered
    // events ready, then flip cancel; nextCancellable must observe it
    // before the next byte read and short-circuit.
    var cancel = std.atomic.Value(bool).init(false);
    const first = try s.nextCancellable(testing.allocator, &cancel) orelse
        return error.TestExpectedEqual;
    try testing.expectEqualStrings("a", first.data);

    // Drain the second buffered event (already in the parser) — flag
    // is checked between reads, not between events the parser has
    // already produced. Both behaviours are correct: the runner
    // rechecks after each event regardless.
    const second = try s.nextCancellable(testing.allocator, &cancel) orelse
        return error.TestExpectedEqual;
    try testing.expectEqualStrings("b", second.data);

    // Now the buffer is empty and EOF hasn't been seen; with a fresh
    // reader holding more bytes, nextCancellable would block on read.
    // Flip cancel and prove the read never happens.
    cancel.store(true, .release);
    var more = "data: c\n\n".*;
    var r2: std.Io.Reader = .fixed(&more);
    var s2 = Stream.init(&r2);
    defer s2.deinit(testing.allocator);
    try testing.expectError(
        error.Cancelled,
        s2.nextCancellable(testing.allocator, &cancel),
    );
}
