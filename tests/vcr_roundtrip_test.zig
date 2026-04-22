//! Integration: record cassette through the Recorder, read back via the
//! Replayer, and assert matcher + consume semantics on a real fixture.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const vcr = tigerclaw.vcr;

const testing = std.testing;

const fixture_bytes = @embedFile("fixture_vcr_cassette.jsonl");

test "fixture: shipped cassette loads and serves both interactions in order" {
    var cs = try vcr.replayer.replayFromBytes(testing.allocator, fixture_bytes);
    defer cs.deinit();

    try testing.expectEqual(@as(u16, 1), cs.header.format_version);
    try testing.expectEqualStrings("fixture-1", cs.header.cassette_id);
    try testing.expectEqual(@as(usize, 2), cs.interactions.len);

    const hi = cs.find(.{}, .{
        .method = "POST",
        .url = "https://api.example.test/v1/chat",
        .body = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    }) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 200), hi.status);
    try testing.expect(std.mem.indexOf(u8, hi.body, "hello") != null);

    const bye = cs.find(.{}, .{
        .method = "POST",
        .url = "https://api.example.test/v1/chat",
        .body = "{\"messages\":[{\"role\":\"user\",\"content\":\"bye\"}]}",
    }) orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, bye.body, "goodbye") != null);
}

test "roundtrip: record → replay preserves every field" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var rec = vcr.Recorder.init(&aw.writer);
    try rec.writeHeader(.{ .cassette_id = "rt", .created_at_ns = 42 });
    try rec.writeInteraction(.{
        .request = .{ .method = "GET", .url = "https://example.test/", .body = null },
        .response = .{ .status = 204, .body = "" },
    });
    try rec.writeInteraction(.{
        .request = .{ .method = "POST", .url = "/v2/x", .body = "{\"a\":1}" },
        .response = .{ .status = 201, .body = "{\"ok\":true}" },
    });
    try rec.flush();

    const bytes = try testing.allocator.dupe(u8, aw.writer.buffered());
    defer testing.allocator.free(bytes);

    var cs = try vcr.replayer.replayFromBytes(testing.allocator, bytes);
    defer cs.deinit();

    try testing.expectEqualStrings("rt", cs.header.cassette_id);
    try testing.expectEqual(@as(i128, 42), cs.header.created_at_ns);

    try testing.expectEqual(@as(usize, 2), cs.interactions.len);

    const r1 = cs.find(.{}, .{ .method = "GET", .url = "https://example.test/" }) orelse
        return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 204), r1.status);

    const r2 = cs.find(.{}, .{ .method = "POST", .url = "/v2/x", .body = "{\"a\":1}" }) orelse
        return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 201), r2.status);
    try testing.expect(std.mem.indexOf(u8, r2.body, "ok") != null);
}

test "unmatched request returns null" {
    var cs = try vcr.replayer.replayFromBytes(testing.allocator, fixture_bytes);
    defer cs.deinit();

    const miss = cs.find(.{}, .{
        .method = "GET",
        .url = "/nope",
    });
    try testing.expect(miss == null);
}
