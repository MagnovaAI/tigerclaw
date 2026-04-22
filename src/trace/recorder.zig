//! Streaming trace recorder.
//!
//! A `Recorder` wraps a `*std.Io.Writer` and writes JSON-lines. The first
//! call MUST be `writeEnvelope`; subsequent calls `writeSpan`. The
//! recorder is intentionally dumb — it does not own the writer, it does
//! not close it, and it does not buffer beyond the writer's own buffer.

const std = @import("std");
const schema = @import("schema.zig");
const span_mod = @import("span.zig");

const Writer = std.Io.Writer;

pub const Recorder = struct {
    out: *Writer,
    envelope_written: bool = false,

    pub const Error = error{
        EnvelopeNotWritten,
        EnvelopeAlreadyWritten,
    } || Writer.Error;

    pub fn init(out: *Writer) Recorder {
        return .{ .out = out };
    }

    pub fn writeEnvelope(self: *Recorder, envelope: schema.Envelope) Error!void {
        if (self.envelope_written) return error.EnvelopeAlreadyWritten;
        try std.json.Stringify.value(envelope, .{}, self.out);
        try self.out.writeByte('\n');
        self.envelope_written = true;
    }

    pub fn writeSpan(self: *Recorder, span: span_mod.Span) Error!void {
        if (!self.envelope_written) return error.EnvelopeNotWritten;
        try std.json.Stringify.value(span, .{}, self.out);
        try self.out.writeByte('\n');
    }

    pub fn flush(self: *Recorder) Writer.Error!void {
        try self.out.flush();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeEnvelope() schema.Envelope {
    return .{
        .trace_id = "trace-1",
        .run_id = "run-1",
        .started_at_ns = 1,
        .mode = .run,
    };
}

fn makeSpan(id: []const u8, start: i128, end: ?i128) span_mod.Span {
    return .{
        .id = id,
        .trace_id = "trace-1",
        .kind = .turn,
        .name = id,
        .started_at_ns = start,
        .finished_at_ns = end,
    };
}

test "Recorder: envelope followed by span produces two JSON lines" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var r = Recorder.init(&aw.writer);
    try r.writeEnvelope(makeEnvelope());
    try r.writeSpan(makeSpan("s1", 0, 5));
    try r.flush();

    const bytes = aw.writer.buffered();
    const nl = std.mem.count(u8, bytes, "\n");
    try testing.expectEqual(@as(usize, 2), nl);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"schema_version\":2") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\":\"s1\"") != null);
}

test "Recorder: writeSpan before envelope is rejected" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var r = Recorder.init(&aw.writer);
    try testing.expectError(
        error.EnvelopeNotWritten,
        r.writeSpan(makeSpan("s1", 0, 1)),
    );
}

test "Recorder: second writeEnvelope is rejected" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var r = Recorder.init(&aw.writer);
    try r.writeEnvelope(makeEnvelope());
    try testing.expectError(
        error.EnvelopeAlreadyWritten,
        r.writeEnvelope(makeEnvelope()),
    );
}
