const std = @import("std");
const t = @import("ctx_types");
const engine = @import("ctx_engine");
const de = @import("ctx_default_engine");
const context_mod = @import("context");
const clock_mod = @import("clock");

test "default engine: ingest stores, assemble returns current_prompt + history" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{
        .session_id = "s1",
        .message_id = "m1",
        .role = .user,
        .content = "hi",
    });

    const res = try eng.vtable.assemble(&ctx, eng.ptr, .{
        .session_id = "s1",
        .prompt = "next question",
        .model = "test",
        .available_tools = &.{},
        .token_budget = 1000,
    });
    defer d.freeAssembleResult(res);

    var saw_prompt = false;
    var saw_history = false;
    for (res.sections) |s| {
        if (s.kind == .current_prompt) saw_prompt = true;
        if (s.kind == .history_turn) saw_history = true;
    }
    try std.testing.expect(saw_prompt);
    try std.testing.expect(saw_history);
}

test "default engine: ingest is idempotent on duplicate message_id" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    const p = t.IngestParams{
        .session_id = "s1",
        .message_id = "m1",
        .role = .user,
        .content = "hi",
    };
    const r1 = try eng.vtable.ingest(&ctx, eng.ptr, p);
    const r2 = try eng.vtable.ingest(&ctx, eng.ptr, p);
    try std.testing.expect(r1.ingested);
    try std.testing.expect(!r2.ingested);
}

test "default engine: session isolation" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "sA", .message_id = "m1", .role = .user, .content = "a" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "sB", .message_id = "m1", .role = .user, .content = "b" });

    const res = try eng.vtable.assemble(&ctx, eng.ptr, .{
        .session_id = "sA",
        .prompt = "q",
        .model = "m",
        .available_tools = &.{},
        .token_budget = 1000,
    });
    defer d.freeAssembleResult(res);

    var history_content: []const u8 = "";
    for (res.sections) |s| {
        if (s.kind == .history_turn) history_content = s.content;
    }
    try std.testing.expectEqualStrings("a", history_content);
}

test "default engine: compact summarizes older turns and keeps recent turns" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 2_000_000 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m001", .role = .user, .content = "first detail" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m002", .role = .assistant, .content = "second detail" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m003", .role = .user, .content = "third detail" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m004", .role = .assistant, .content = "recent detail" });

    const compacted = try eng.vtable.compact(&ctx, eng.ptr, .{
        .session_id = "s1",
        .token_budget = 1,
        .force = true,
    });
    defer allocator.free(compacted.summary_entry_id.?);
    try std.testing.expect(compacted.compacted);

    const res = try eng.vtable.assemble(&ctx, eng.ptr, .{
        .session_id = "s1",
        .prompt = "next",
        .model = "test",
        .available_tools = &.{},
        .token_budget = 1000,
    });
    defer d.freeAssembleResult(res);

    var saw_summary = false;
    var history_count: usize = 0;
    for (res.sections) |s| {
        if (s.kind == .compaction_summary) {
            saw_summary = true;
            try std.testing.expect(std.mem.indexOf(u8, s.content, "first detail") != null);
        }
        if (s.kind == .history_turn) history_count += 1;
    }
    try std.testing.expect(saw_summary);
    try std.testing.expectEqual(@as(usize, 2), history_count);
}

test "default engine: recall returns matching visible history" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m1", .role = .user, .content = "Project codename is cedar" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m2", .role = .assistant, .content = "Unrelated" });

    const recalled = try eng.vtable.recall(&ctx, eng.ptr, .{
        .session_id = "s1",
        .query = "CEDAR",
        .k = 3,
    });
    defer {
        for (recalled.hits) |h| {
            allocator.free(h.entry_id);
            allocator.free(h.snippet);
        }
        allocator.free(recalled.hits);
    }

    try std.testing.expectEqual(@as(usize, 1), recalled.hits.len);
    try std.testing.expectEqualStrings("m1", recalled.hits[0].entry_id);
}

test "default engine: compaction markers are session scoped" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();

    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    const eng = d.engine();
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m001", .role = .user, .content = "s1 old" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m002", .role = .user, .content = "s1 middle" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s1", .message_id = "m003", .role = .user, .content = "s1 keep" });
    _ = try eng.vtable.ingest(&ctx, eng.ptr, .{ .session_id = "s2", .message_id = "m001", .role = .user, .content = "s2 same id" });

    const compacted = try eng.vtable.compact(&ctx, eng.ptr, .{
        .session_id = "s1",
        .token_budget = 1,
        .force = true,
    });
    defer allocator.free(compacted.summary_entry_id.?);

    const res = try eng.vtable.assemble(&ctx, eng.ptr, .{
        .session_id = "s2",
        .prompt = "next",
        .model = "test",
        .available_tools = &.{},
        .token_budget = 1000,
    });
    defer d.freeAssembleResult(res);

    var saw_s2_history = false;
    for (res.sections) |s| {
        if (s.kind == .history_turn and std.mem.eql(u8, s.content, "s2 same id")) saw_s2_history = true;
        try std.testing.expect(s.kind != .compaction_summary);
    }
    try std.testing.expect(saw_s2_history);
}
