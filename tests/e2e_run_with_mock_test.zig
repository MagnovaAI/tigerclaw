//! End-to-end: the `run` entrypoint against a mock provider.
//!
//! This is the first wiring that exercises the whole stack —
//! harness + session + provider dispatch + persistence — from the
//! outside. If it breaks, a plain `tigerclaw run` is broken.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const run = tigerclaw.entrypoints.run;
const llm = tigerclaw.llm;
const clock = tigerclaw.clock;

test "e2e: run produces a session file and prints the assistant text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "pong", .usage = .{ .input = 2, .output = 1 } },
    };
    var mock = llm.MockProvider{ .replies = &replies };

    var mc = clock.ManualClock{ .value_ns = 42 };
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const result = try run.run(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
        .provider = mock.provider(),
        .session_id = "e2e",
        .user_input = "ping",
        .model = .{ .provider = "mock", .model = "0" },
        .output = &out,
    });

    try testing.expectEqual(@as(u32, 1), result.turn_count);
    try testing.expectEqual(@as(u32, 2), result.usage.input);
    try testing.expectEqual(@as(u32, 1), result.usage.output);
    try testing.expectEqualStrings("pong\n", out.buffered());

    // The saved session file must be readable as JSON and hold
    // the single turn we just ran.
    var read_buf: [4 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "e2e.json", &read_buf);
    const parsed = try tigerclaw.harness.state.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqualStrings("e2e", parsed.value.id);
    try testing.expectEqual(@as(u32, 1), parsed.value.turn_count);
    try testing.expectEqualStrings("ping", parsed.value.turns[0].user.content);
    try testing.expectEqualStrings("pong", parsed.value.turns[0].assistant.content);
}

test "e2e: back-to-back runs with resume_if_exists accumulate turns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "first" },
        .{ .text = "second" },
        .{ .text = "third" },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var mc = clock.ManualClock{ .value_ns = 10 };
    var out_buf: [512]u8 = undefined;

    const ids = [_][]const u8{ "q1", "q2", "q3" };
    var i: usize = 0;
    while (i < ids.len) : (i += 1) {
        var out: std.Io.Writer = .fixed(&out_buf);
        const r = try run.run(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
            .provider = mock.provider(),
            .session_id = "conv",
            .user_input = ids[i],
            .model = .{ .provider = "mock", .model = "0" },
            .output = &out,
            .resume_if_exists = true,
        });
        try testing.expectEqual(@as(u32, @intCast(i + 1)), r.turn_count);
        mc.advance(5);
    }

    var read_buf: [4 * 1024]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "conv.json", &read_buf);
    const parsed = try tigerclaw.harness.state.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 3), parsed.value.turn_count);
    try testing.expectEqualStrings("first", parsed.value.turns[0].assistant.content);
    try testing.expectEqualStrings("third", parsed.value.turns[2].assistant.content);
}

test "e2e: doctor produces an ok report on a clean install" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    const r = try tigerclaw.entrypoints.doctor.doctor(.{
        .io = testing.io,
        .state_dir = tmp.dir,
        .mode = .run,
        .output = &out,
    });
    try testing.expect(r.ok);
    try testing.expect(r.checks_run > 0);
    try testing.expectEqual(@as(u32, 0), r.checks_failed);
}

test "e2e: list reports the sessions that run() created" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const replies = [_]llm.providers.mock.Reply{
        .{ .text = "r" },
        .{ .text = "r" },
    };
    var mock = llm.MockProvider{ .replies = &replies };
    var mc = clock.ManualClock{ .value_ns = 1 };
    var sink: [256]u8 = undefined;

    for ([_][]const u8{ "a", "b" }) |id| {
        var out: std.Io.Writer = .fixed(&sink);
        _ = try run.run(.{
            .allocator = testing.allocator,
            .clock = mc.clock(),
            .io = testing.io,
            .state_dir = tmp.dir,
            .provider = mock.provider(),
            .session_id = id,
            .user_input = "hi",
            .model = .{ .provider = "mock", .model = "0" },
            .output = &out,
        });
    }

    var list_buf: [512]u8 = undefined;
    var list_out: std.Io.Writer = .fixed(&list_buf);
    const lr = try tigerclaw.entrypoints.list.list(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .state_dir = tmp.dir,
        .output = &list_out,
    });

    try testing.expectEqual(@as(usize, 2), lr.count);
    const text = list_out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "a\t1\t") != null);
    try testing.expect(std.mem.indexOf(u8, text, "b\t1\t") != null);
}
