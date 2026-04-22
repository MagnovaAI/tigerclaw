//! E2E replay round-trip: record a session's turns, load the
//! JSON back, and confirm a deterministic second "run" against
//! the same mock script produces identical transcripts.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const entrypoints = tigerclaw.entrypoints;
const llm = tigerclaw.llm;
const clock = tigerclaw.clock;

test "e2e replay: two mock runs against identical scripts produce identical session JSON" {
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "one", .stop_reason = .end_turn },
        .{ .text = "two", .stop_reason = .end_turn },
    };
    var mock_a = llm.MockProvider{ .replies = &replies };
    var mock_b = llm.MockProvider{ .replies = &replies };

    var clock_a = clock.ManualClock{ .value_ns = 1 };
    var clock_b = clock.ManualClock{ .value_ns = 1 };

    var sink_a: [256]u8 = undefined;
    var sink_b: [256]u8 = undefined;

    const prompts = [_][]const u8{ "q1", "q2" };

    for (prompts) |p| {
        var oa: std.Io.Writer = .fixed(&sink_a);
        _ = try entrypoints.run.run(.{
            .allocator = testing.allocator,
            .clock = clock_a.clock(),
            .io = testing.io,
            .state_dir = tmp_a.dir,
            .provider = mock_a.provider(),
            .session_id = "s",
            .user_input = p,
            .model = .{ .provider = "mock", .model = "0" },
            .output = &oa,
            .resume_if_exists = true,
        });
        var ob: std.Io.Writer = .fixed(&sink_b);
        _ = try entrypoints.run.run(.{
            .allocator = testing.allocator,
            .clock = clock_b.clock(),
            .io = testing.io,
            .state_dir = tmp_b.dir,
            .provider = mock_b.provider(),
            .session_id = "s",
            .user_input = p,
            .model = .{ .provider = "mock", .model = "0" },
            .output = &ob,
            .resume_if_exists = true,
        });
    }

    // Compare the two persisted session files byte-for-byte.
    var buf_a: [4 * 1024]u8 = undefined;
    var buf_b: [4 * 1024]u8 = undefined;
    const bytes_a = try tmp_a.dir.readFile(testing.io, "s.json", &buf_a);
    const bytes_b = try tmp_b.dir.readFile(testing.io, "s.json", &buf_b);
    try testing.expectEqualStrings(bytes_a, bytes_b);
}
