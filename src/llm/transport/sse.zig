//! Server-sent-events parser.
//!
//! Bytes in, events out. Strictly a parser — no I/O, no allocator on the
//! hot path. A `Parser` accepts partial input via `feed`; it buffers until
//! it sees a blank-line terminator, at which point it emits an `Event`.
//!
//! The subset handled here is the one that every provider we target
//! actually sends:
//!
//!   event: <name>
//!   data: <line 1>
//!   data: <line 2>
//!   <blank>
//!
//! Multiple `data:` lines concatenate with newlines (per the WHATWG spec).
//! `id:` and `retry:` fields are parsed and exposed; unknown field names
//! are ignored. Comment lines starting with `:` are dropped.

const std = @import("std");

pub const Event = struct {
    name: []const u8 = "", // Empty means "default message" in the spec.
    data: []const u8 = "",
    id: []const u8 = "",
    retry_ms: ?u32 = null,
};

const EventBuilder = struct {
    name: std.array_list.Aligned(u8, null) = .empty,
    data: std.array_list.Aligned(u8, null) = .empty,
    id: std.array_list.Aligned(u8, null) = .empty,
    retry_ms: ?u32 = null,

    fn deinit(self: *EventBuilder, allocator: std.mem.Allocator) void {
        self.name.deinit(allocator);
        self.data.deinit(allocator);
        self.id.deinit(allocator);
    }
};

pub const Parser = struct {
    buf: std.array_list.Aligned(u8, null) = .empty,
    current: EventBuilder = .{},
    scratch: [4096]u8 = undefined,

    pub fn init() Parser {
        return .{};
    }

    pub fn deinit(self: *Parser, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.current.deinit(allocator);
    }

    /// Appends `bytes` to the working buffer. Does not parse on its own;
    /// call `nextEvent` until it returns null to drain pending events.
    pub fn feed(self: *Parser, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
    }

    /// Returns the next complete event, or null if the buffer does not
    /// contain a full one yet. The event's slices reference memory owned
    /// by the parser and are invalidated by the next call to `nextEvent`
    /// or `feed` — callers that keep events across calls must copy.
    pub fn nextEvent(self: *Parser, allocator: std.mem.Allocator) !?Event {
        while (true) {
            const line_opt = self.consumeLine() catch |err| switch (err) {
                error.Incomplete => return null,
                else => return err,
            };
            const line = line_opt orelse {
                // Blank line terminates an event, but only if we have content.
                if (!self.hasContent()) continue;
                return self.flushEvent();
            };
            try self.handleLine(allocator, line);
        }
    }

    fn consumeLine(self: *Parser) !?[]const u8 {
        const bytes = self.buf.items;
        const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.Incomplete;
        var line_end = nl;
        // Support \r\n as well.
        if (line_end > 0 and bytes[line_end - 1] == '\r') line_end -= 1;
        const line = bytes[0..line_end];

        if (line.len == 0) {
            // Blank line: consume the newline and signal terminator.
            self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            return null;
        }

        // Cache the line contents before shifting.
        var cache: [4096]u8 = undefined;
        if (line.len > cache.len) return error.LineTooLong;
        @memcpy(cache[0..line.len], line);
        self.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
        // We need a stable reference; copy into a small scratch buffer on
        // the parser. Reusing a fixed buffer is safe because the caller
        // promises not to reach back into earlier lines.
        @memcpy(self.scratch[0..line.len], cache[0..line.len]);
        return self.scratch[0..line.len];
    }

    fn handleLine(self: *Parser, allocator: std.mem.Allocator, line: []const u8) !void {
        if (line.len == 0) return;
        if (line[0] == ':') return; // comment

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value = if (colon) |c| line[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            try replaceSlice(&self.current.name, allocator, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (self.current.data.items.len > 0) try self.current.data.append(allocator, '\n');
            try self.current.data.appendSlice(allocator, value);
        } else if (std.mem.eql(u8, field, "id")) {
            try replaceSlice(&self.current.id, allocator, value);
        } else if (std.mem.eql(u8, field, "retry")) {
            const ms = std.fmt.parseInt(u32, value, 10) catch null;
            if (ms) |m| self.current.retry_ms = m;
        } else {
            // Unknown field: ignore.
        }
    }

    fn hasContent(self: *const Parser) bool {
        return self.current.name.items.len > 0 or
            self.current.data.items.len > 0 or
            self.current.id.items.len > 0 or
            self.current.retry_ms != null;
    }

    fn flushEvent(self: *Parser) Event {
        const ev = Event{
            .name = self.current.name.items,
            .data = self.current.data.items,
            .id = self.current.id.items,
            .retry_ms = self.current.retry_ms,
        };
        // Mark the builder empty without freeing so the next feed reuses
        // capacity. Caller must consume the returned slices before the
        // next call.
        self.current.name.items.len = 0;
        self.current.data.items.len = 0;
        self.current.id.items.len = 0;
        self.current.retry_ms = null;
        return ev;
    }
};

fn replaceSlice(
    list: *std.array_list.Aligned(u8, null),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(allocator, value);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Parser: single event with event + data emits both" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "event: greet\ndata: hello\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("greet", ev.name);
    try testing.expectEqualStrings("hello", ev.data);

    try testing.expect((try p.nextEvent(testing.allocator)) == null);
}

test "Parser: multiple data lines concatenate with newline" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "data: line-a\ndata: line-b\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("line-a\nline-b", ev.data);
}

test "Parser: comments (lines starting with ':') are dropped" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, ": heartbeat\ndata: payload\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("payload", ev.data);
}

test "Parser: retry field parses milliseconds" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "retry: 1500\ndata: x\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(?u32, 1500), ev.retry_ms);
}

test "Parser: \\r\\n line endings are honoured" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "event: x\r\ndata: y\r\n\r\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("x", ev.name);
    try testing.expectEqualStrings("y", ev.data);
}

test "Parser: partial bytes buffer until terminator arrives" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "data: ");
    try testing.expect((try p.nextEvent(testing.allocator)) == null);
    try p.feed(testing.allocator, "pay");
    try testing.expect((try p.nextEvent(testing.allocator)) == null);
    try p.feed(testing.allocator, "load\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("payload", ev.data);
}

test "Parser: two events in a row can both be drained" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "data: a\n\ndata: b\n\n");

    const first = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("a", first.data);

    const second = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("b", second.data);

    try testing.expect((try p.nextEvent(testing.allocator)) == null);
}

test "Parser: unknown fields are dropped" {
    var p = Parser.init();
    defer p.deinit(testing.allocator);

    try p.feed(testing.allocator, "weird: stuff\ndata: kept\n\n");
    const ev = try p.nextEvent(testing.allocator) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("kept", ev.data);
}
