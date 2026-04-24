const std = @import("std");
const t = @import("ctx_types");
const engine = @import("ctx_engine");
const de = @import("ctx_default_engine");
const context_mod = @import("context");
const clock_mod = @import("clock");

fn runContract(eng: engine.ContextEngine, allocator: std.mem.Allocator) !void {
    var fixed = clock_mod.FixedClock{ .value_ns = 0 };
    const clk = fixed.clock();
    const ctx = context_mod.Context.initForTest(allocator, &clk);

    // Invariant 1: ingest is idempotent on (session_id, message_id).
    const p = t.IngestParams{ .session_id = "s", .message_id = "m1", .role = .user, .content = "x" };
    const r1 = try eng.vtable.ingest(&ctx, eng.ptr, p);
    const r2 = try eng.vtable.ingest(&ctx, eng.ptr, p);
    try std.testing.expect(r1.ingested);
    try std.testing.expect(!r2.ingested);

    // Invariant 2+3+4: assemble is deterministic, respects budget, includes current_prompt.
    const ap = t.AssembleParams{
        .session_id = "s",
        .prompt = "q",
        .model = "m",
        .available_tools = &.{},
        .token_budget = 1000,
    };
    const a1 = try eng.vtable.assemble(&ctx, eng.ptr, ap);
    const a2 = try eng.vtable.assemble(&ctx, eng.ptr, ap);

    // The engine may not expose a freeAssembleResult in its public vtable,
    // but DefaultEngine does. For contract purposes, we free via allocator
    // directly because the slices come from it.
    defer allocator.free(a1.sections);
    defer allocator.free(a1.dropped);
    defer allocator.free(a2.sections);
    defer allocator.free(a2.dropped);

    try std.testing.expectEqual(a1.estimated_tokens, a2.estimated_tokens);
    try std.testing.expectEqual(a1.sections.len, a2.sections.len);
    try std.testing.expect(a1.estimated_tokens <= 1000);

    var saw_prompt = false;
    for (a1.sections) |s| if (s.kind == .current_prompt) {
        saw_prompt = true;
    };
    try std.testing.expect(saw_prompt);
}

test "default engine passes context_engine contract" {
    const allocator = std.testing.allocator;
    var d = try de.DefaultEngine.init(allocator);
    defer d.deinit();
    try runContract(d.engine(), allocator);
}
