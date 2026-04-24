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
