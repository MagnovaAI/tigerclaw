//! Small builder for in-memory trace bytes, used by tests that want to
//! exercise the replayer / diff without hitting the filesystem.

const std = @import("std");
const schema = @import("schema.zig");
const span_mod = @import("span.zig");
const recorder = @import("recorder.zig");

pub const Builder = struct {
    aw: std.Io.Writer.Allocating,
    envelope_written: bool = false,
    finalised: bool = false,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .aw = .init(allocator) };
    }

    pub fn writeEnvelope(self: *Builder, envelope: schema.Envelope) !void {
        std.debug.assert(!self.envelope_written);
        var rec = recorder.Recorder.init(&self.aw.writer);
        try rec.writeEnvelope(envelope);
        self.envelope_written = true;
    }

    pub fn append(self: *Builder, s: span_mod.Span) !void {
        std.debug.assert(self.envelope_written);
        var rec = recorder.Recorder.init(&self.aw.writer);
        // We've already written the envelope; advance the recorder state
        // so writeSpan is allowed.
        rec.envelope_written = true;
        try rec.writeSpan(s);
    }

    /// Takes ownership of the written bytes. Subsequent calls fail.
    pub fn toOwnedBytes(self: *Builder, allocator: std.mem.Allocator) ![]u8 {
        std.debug.assert(!self.finalised);
        self.finalised = true;
        try self.aw.writer.flush();
        return try allocator.dupe(u8, self.aw.writer.buffered());
    }

    pub fn deinit(self: *Builder) void {
        self.aw.deinit();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Builder: envelope + 2 spans produces 3 JSON lines" {
    const envelope = schema.Envelope{
        .trace_id = "t",
        .run_id = "r",
        .started_at_ns = 0,
        .mode = .run,
    };

    var b = Builder.init(testing.allocator);
    defer b.deinit();

    try b.writeEnvelope(envelope);

    try b.append(.{
        .id = "s1",
        .trace_id = "t",
        .kind = .root,
        .name = "root",
        .started_at_ns = 0,
        .finished_at_ns = 1,
    });
    try b.append(.{
        .id = "s2",
        .parent_id = "s1",
        .trace_id = "t",
        .kind = .turn,
        .name = "turn-1",
        .started_at_ns = 1,
        .finished_at_ns = 2,
    });

    const bytes = try b.toOwnedBytes(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\n"));
}
