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
        while (true) {
            if (try self.parser.nextEvent(allocator)) |ev| return ev;
            if (self.eof) return null;

            const n = try self.reader.readSliceShort(&self.chunk);
            if (n == 0) {
                self.eof = true;
                return try self.parser.nextEvent(allocator);
            }
            try self.parser.feed(allocator, self.chunk[0..n]);
        }
    }
};

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
