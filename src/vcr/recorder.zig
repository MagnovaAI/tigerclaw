//! Writes a cassette: header followed by a stream of interactions.
//!
//! Mirrors the shape of `trace/recorder.zig`. Holds a `*std.Io.Writer`;
//! does not own or close it.

const std = @import("std");
const cassette = @import("cassette.zig");

const Writer = std.Io.Writer;

pub const Recorder = struct {
    out: *Writer,
    header_written: bool = false,

    pub const Error = error{
        HeaderNotWritten,
        HeaderAlreadyWritten,
    } || Writer.Error;

    pub fn init(out: *Writer) Recorder {
        return .{ .out = out };
    }

    pub fn writeHeader(self: *Recorder, header: cassette.Header) Error!void {
        if (self.header_written) return error.HeaderAlreadyWritten;
        try std.json.Stringify.value(header, .{}, self.out);
        try self.out.writeByte('\n');
        self.header_written = true;
    }

    pub fn writeInteraction(self: *Recorder, interaction: cassette.Interaction) Error!void {
        if (!self.header_written) return error.HeaderNotWritten;
        try std.json.Stringify.value(interaction, .{}, self.out);
        try self.out.writeByte('\n');
    }

    pub fn flush(self: *Recorder) Writer.Error!void {
        try self.out.flush();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Recorder: header + interaction produces 2 lines" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var rec = Recorder.init(&aw.writer);
    try rec.writeHeader(.{ .cassette_id = "c", .created_at_ns = 0 });
    try rec.writeInteraction(.{
        .request = .{ .method = "POST", .url = "/x", .body = "req" },
        .response = .{ .status = 200, .body = "resp" },
    });
    try rec.flush();

    const bytes = aw.writer.buffered();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\n"));
    try testing.expect(std.mem.indexOf(u8, bytes, "\"format_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"method\":\"POST\"") != null);
}

test "Recorder: interaction before header rejected" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var rec = Recorder.init(&aw.writer);
    try testing.expectError(error.HeaderNotWritten, rec.writeInteraction(.{
        .request = .{ .method = "GET", .url = "/x" },
        .response = .{ .status = 200, .body = "" },
    }));
}

test "Recorder: second header rejected" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var rec = Recorder.init(&aw.writer);
    try rec.writeHeader(.{ .cassette_id = "c", .created_at_ns = 0 });
    try testing.expectError(
        error.HeaderAlreadyWritten,
        rec.writeHeader(.{ .cassette_id = "d", .created_at_ns = 1 }),
    );
}
