//! Streaming SSE parser for the TUI side of `/sessions/:id/turns`.
//!
//! The gateway emits v1-compatible JSON-envelope frames:
//!
//!     data: {"type":"chunk","text":"..."}\n\n
//!     data: {"type":"tool_start","id":"...","name":"..."}\n\n
//!     data: {"type":"tool_progress","id":"...","stream":"stdout|stderr","chunk":"..."}\n\n
//!     data: {"type":"tool_done","id":"...","name":"...","output":"..."}\n\n
//!     data: {"type":"done"}\n\n
//!     data: {"type":"error","message":"..."}\n\n
//!
//! This module decodes those frames incrementally: callers feed bytes
//! in as they arrive and the parser invokes a typed `Event` callback
//! per complete frame. Unknown `type` values are dropped silently so
//! the gateway can add new event kinds without the client needing a
//! version bump.
//!
//! The parser owns a small scratch buffer it grows on demand. The
//! caller is expected to keep the parser alive for the full response
//! and call `deinit` when the HTTP stream ends.

const std = @import("std");

pub const StreamSide = enum { stdout, stderr };

pub const Event = union(enum) {
    chunk: []const u8, // borrowed
    tool_start: struct { id: []const u8, name: []const u8 },
    tool_progress: struct { id: []const u8, stream: StreamSide, chunk: []const u8 },
    tool_done: struct { id: []const u8, name: []const u8, output: []const u8 },
    done,
    err: []const u8,
};

/// Called once per complete frame. Slices in the event are borrowed
/// from the parser's scratch buffer and are only valid until the
/// callback returns.
pub const Sink = *const fn (ctx: ?*anyopaque, event: Event) void;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator, .buf = .empty };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.allocator);
    }

    /// Feed more bytes, extract every completed frame, and invoke the
    /// sink per frame. Incomplete trailing bytes stay in the buffer
    /// for the next call.
    pub fn feed(
        self: *Parser,
        bytes: []const u8,
        sink: Sink,
        sink_ctx: ?*anyopaque,
    ) !void {
        try self.buf.appendSlice(self.allocator, bytes);

        // Walk `\n\n` boundaries. Keep the tail (incomplete frame)
        // in the buffer for the next feed.
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, self.buf.items, start, "\n\n")) |end| {
            const frame = self.buf.items[start..end];
            dispatchFrame(frame, sink, sink_ctx);
            start = end + 2;
        }

        if (start > 0) {
            const remainder = self.buf.items[start..];
            if (remainder.len == 0) {
                self.buf.clearRetainingCapacity();
            } else {
                // Shift the tail to the front. `copyForwards` is
                // safe for overlapping ranges.
                std.mem.copyForwards(u8, self.buf.items, remainder);
                self.buf.shrinkRetainingCapacity(remainder.len);
            }
        }
    }

    fn dispatchFrame(frame: []const u8, sink: Sink, sink_ctx: ?*anyopaque) void {
        // Each frame is a sequence of `field: value\n` lines. We only
        // care about `data:` lines and concatenate multiple into one
        // payload per the SSE spec, though the gateway emits one
        // `data:` per frame in practice.
        var data_buf: [8 * 1024]u8 = undefined;
        var data_len: usize = 0;
        var line_it = std.mem.splitScalar(u8, frame, '\n');
        while (line_it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            var payload = line[5..];
            if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
            const take = @min(payload.len, data_buf.len - data_len);
            @memcpy(data_buf[data_len .. data_len + take], payload[0..take]);
            data_len += take;
        }
        if (data_len == 0) return;

        parseAndDispatch(data_buf[0..data_len], sink, sink_ctx);
    }

    /// Parse the JSON payload and invoke the sink with a typed event.
    /// Malformed JSON or unknown `type` values are silently dropped
    /// so future event types don't require a client release.
    fn parseAndDispatch(payload: []const u8, sink: Sink, sink_ctx: ?*anyopaque) void {
        // Use an arena for the parse so every string inside the
        // parsed object is freed together at scope end. The sink is
        // invoked synchronously with borrowed slices — it must copy
        // anything it needs to retain.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch return;
        if (parsed.value != .object) return;

        const type_v = parsed.value.object.get("type") orelse return;
        if (type_v != .string) return;

        const kind = type_v.string;
        if (std.mem.eql(u8, kind, "chunk")) {
            const text = parsed.value.object.get("text") orelse return;
            if (text != .string) return;
            sink(sink_ctx, .{ .chunk = text.string });
        } else if (std.mem.eql(u8, kind, "tool_start")) {
            const id = parsed.value.object.get("id") orelse return;
            const name = parsed.value.object.get("name") orelse return;
            if (id != .string or name != .string) return;
            sink(sink_ctx, .{ .tool_start = .{ .id = id.string, .name = name.string } });
        } else if (std.mem.eql(u8, kind, "tool_progress")) {
            const id = parsed.value.object.get("id") orelse return;
            const stream_v = parsed.value.object.get("stream") orelse return;
            const chunk = parsed.value.object.get("chunk") orelse return;
            if (id != .string or stream_v != .string or chunk != .string) return;
            const stream: StreamSide = if (std.mem.eql(u8, stream_v.string, "stderr")) .stderr else .stdout;
            sink(sink_ctx, .{ .tool_progress = .{
                .id = id.string,
                .stream = stream,
                .chunk = chunk.string,
            } });
        } else if (std.mem.eql(u8, kind, "tool_done")) {
            const id = parsed.value.object.get("id") orelse return;
            const name = parsed.value.object.get("name") orelse return;
            const output = parsed.value.object.get("output") orelse return;
            if (id != .string or name != .string or output != .string) return;
            sink(sink_ctx, .{ .tool_done = .{
                .id = id.string,
                .name = name.string,
                .output = output.string,
            } });
        } else if (std.mem.eql(u8, kind, "done")) {
            sink(sink_ctx, .done);
        } else if (std.mem.eql(u8, kind, "error")) {
            const msg = parsed.value.object.get("message") orelse {
                sink(sink_ctx, .{ .err = "unknown error" });
                return;
            };
            if (msg != .string) return;
            sink(sink_ctx, .{ .err = msg.string });
        }
        // Unknown types are silently dropped — keeps the wire
        // forward-compatible with new event kinds.
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Collector = struct {
    events: std.ArrayList(u8) = .empty,

    fn sink(ctx: ?*anyopaque, event: Event) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .chunk => |t| {
                self.events.appendSlice(testing.allocator, "chunk:") catch return;
                self.events.appendSlice(testing.allocator, t) catch return;
                self.events.append(testing.allocator, '|') catch return;
            },
            .tool_start => |ts| {
                self.events.appendSlice(testing.allocator, "tool_start:") catch return;
                self.events.appendSlice(testing.allocator, ts.name) catch return;
                self.events.append(testing.allocator, '|') catch return;
            },
            .tool_progress => |tp| {
                self.events.appendSlice(testing.allocator, "tool_progress:") catch return;
                self.events.appendSlice(testing.allocator, switch (tp.stream) {
                    .stdout => "out",
                    .stderr => "err",
                }) catch return;
                self.events.append(testing.allocator, ':') catch return;
                self.events.appendSlice(testing.allocator, tp.chunk) catch return;
                self.events.append(testing.allocator, '|') catch return;
            },
            .tool_done => |td| {
                self.events.appendSlice(testing.allocator, "tool_done:") catch return;
                self.events.appendSlice(testing.allocator, td.name) catch return;
                self.events.append(testing.allocator, ':') catch return;
                self.events.appendSlice(testing.allocator, td.output) catch return;
                self.events.append(testing.allocator, '|') catch return;
            },
            .done => self.events.appendSlice(testing.allocator, "done|") catch return,
            .err => |m| {
                self.events.appendSlice(testing.allocator, "err:") catch return;
                self.events.appendSlice(testing.allocator, m) catch return;
                self.events.append(testing.allocator, '|') catch return;
            },
        }
    }

    fn deinit(self: *Collector) void {
        self.events.deinit(testing.allocator);
    }
};

test "Parser: emits chunk events in order with correct text" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed(
        "data: {\"type\":\"chunk\",\"text\":\"hello \"}\n\ndata: {\"type\":\"chunk\",\"text\":\"world\"}\n\ndata: {\"type\":\"done\"}\n\n",
        Collector.sink,
        &c,
    );
    try testing.expectEqualStrings("chunk:hello |chunk:world|done|", c.events.items);
}

test "Parser: frames split across feeds are reassembled" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed("data: {\"type\":\"chun", Collector.sink, &c);
    try testing.expectEqualStrings("", c.events.items);
    try p.feed("k\",\"text\":\"ok\"}\n\n", Collector.sink, &c);
    try testing.expectEqualStrings("chunk:ok|", c.events.items);
}

test "Parser: tool_start and tool_done decode name + output" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed(
        "data: {\"type\":\"tool_start\",\"id\":\"t1\",\"name\":\"get_current_time\"}\n\ndata: {\"type\":\"tool_done\",\"id\":\"t1\",\"name\":\"get_current_time\",\"output\":\"2026-04-24T00:00:00Z\"}\n\n",
        Collector.sink,
        &c,
    );
    try testing.expectEqualStrings(
        "tool_start:get_current_time|tool_done:get_current_time:2026-04-24T00:00:00Z|",
        c.events.items,
    );
}

test "Parser: tool_progress decodes stream and chunk" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed(
        "data: {\"type\":\"tool_progress\",\"id\":\"t1\",\"stream\":\"stdout\",\"chunk\":\"hello\"}\n\n" ++
            "data: {\"type\":\"tool_progress\",\"id\":\"t1\",\"stream\":\"stderr\",\"chunk\":\"oops\"}\n\n",
        Collector.sink,
        &c,
    );
    try testing.expectEqualStrings(
        "tool_progress:out:hello|tool_progress:err:oops|",
        c.events.items,
    );
}

test "Parser: unknown event types are dropped silently" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed(
        "data: {\"type\":\"thinking\"}\n\ndata: {\"type\":\"chunk\",\"text\":\"x\"}\n\n",
        Collector.sink,
        &c,
    );
    try testing.expectEqualStrings("chunk:x|", c.events.items);
}

test "Parser: malformed JSON does not crash or emit" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed("data: {not-json}\n\ndata: {\"type\":\"chunk\",\"text\":\"x\"}\n\n", Collector.sink, &c);
    try testing.expectEqualStrings("chunk:x|", c.events.items);
}

test "Parser: error frame surfaces the message" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    var c: Collector = .{};
    defer c.deinit();

    try p.feed("data: {\"type\":\"error\",\"message\":\"oops\"}\n\n", Collector.sink, &c);
    try testing.expectEqualStrings("err:oops|", c.events.items);
}
