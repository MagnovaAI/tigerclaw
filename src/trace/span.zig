//! Trace spans.
//!
//! A span records a bounded piece of work: a tool call, a provider
//! request, a turn, a compaction pass. Spans are content-addressed by
//! `(trace_id, parent_id, name, started_at_ns)`; callers are responsible
//! for generating stable `id`s deterministically (see `determinism.zig`).
//!
//! Spans are serialised one per line. `finished_at_ns` is nullable so the
//! recorder can flush an "open" span at crash time without synthesising a
//! false end time.

const std = @import("std");

pub const Kind = enum {
    root,
    turn,
    provider_request,
    tool_call,
    context_op,
    custom,

    pub fn jsonStringify(self: Kind, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Kind {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(Kind, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Status = enum {
    ok,
    err,
    cancelled,

    pub fn jsonStringify(self: Status, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Status {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(Status, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

pub const Span = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    trace_id: []const u8,
    kind: Kind,
    name: []const u8,
    started_at_ns: i128,
    finished_at_ns: ?i128 = null,
    status: Status = .ok,
    /// Optional JSON-encoded attributes. Callers own the allocation.
    attributes_json: ?[]const u8 = null,

    pub fn durationNs(self: Span) ?i128 {
        const end = self.finished_at_ns orelse return null;
        return end - self.started_at_ns;
    }

    pub fn isOpen(self: Span) bool {
        return self.finished_at_ns == null;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Span: JSON roundtrip preserves every field" {
    const s = Span{
        .id = "span-1",
        .parent_id = "span-0",
        .trace_id = "trace-x",
        .kind = .tool_call,
        .name = "read_file",
        .started_at_ns = 100,
        .finished_at_ns = 250,
        .status = .ok,
        .attributes_json = "{\"path\":\"/tmp/x\"}",
    };

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, s, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Span, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("span-1", parsed.value.id);
    try testing.expectEqualStrings("span-0", parsed.value.parent_id.?);
    try testing.expectEqualStrings("trace-x", parsed.value.trace_id);
    try testing.expectEqual(Kind.tool_call, parsed.value.kind);
    try testing.expectEqualStrings("read_file", parsed.value.name);
    try testing.expectEqual(@as(i128, 100), parsed.value.started_at_ns);
    try testing.expectEqual(@as(i128, 250), parsed.value.finished_at_ns.?);
    try testing.expectEqual(Status.ok, parsed.value.status);
    try testing.expectEqualStrings("{\"path\":\"/tmp/x\"}", parsed.value.attributes_json.?);
}

test "Span: open spans have no finish time" {
    const s = Span{
        .id = "span-open",
        .trace_id = "t",
        .kind = .turn,
        .name = "turn-1",
        .started_at_ns = 10,
    };
    try testing.expect(s.isOpen());
    try testing.expect(s.durationNs() == null);
}

test "Span: duration is finish minus start" {
    const s = Span{
        .id = "x",
        .trace_id = "t",
        .kind = .turn,
        .name = "turn-2",
        .started_at_ns = 100,
        .finished_at_ns = 175,
    };
    try testing.expectEqual(@as(i128, 75), s.durationNs().?);
}

test "Kind: unknown variant rejected on parse" {
    const bad =
        \\{"id":"x","trace_id":"t","kind":"bogus","name":"n","started_at_ns":0}
    ;
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Span, testing.allocator, bad, .{}),
    );
}

test "Status: err variant roundtrips" {
    const s = Span{
        .id = "x",
        .trace_id = "t",
        .kind = .provider_request,
        .name = "chat",
        .started_at_ns = 0,
        .finished_at_ns = 1,
        .status = .err,
    };
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, s, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Span, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(Status.err, parsed.value.status);
}
