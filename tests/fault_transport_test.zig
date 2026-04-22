//! Integration: fault_injector fires scripted errors through a real
//! Anthropic parser target, and the breaker then records the trip.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const llm = tigerclaw.llm;

const testing = std.testing;

const anthropic_stream =
    "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"reply\"}}\n\n";

fn emptyMessages() [0]tigerclaw.types.Message {
    return .{};
}

test "fault_injector + breaker: scripted failure trips breaker; later success closes it" {
    var anth = llm.providers.AnthropicProvider.init(.{ .literal = anthropic_stream });
    const steps = [_]llm.reliability.Fault{
        .{ .inject = error.Unavailable },
        .pass,
    };
    var script = llm.reliability.FaultScript.init(&steps);
    var inj = llm.reliability.FaultInjector.init(anth.provider(), &script);
    var breaker = llm.reliability.Breaker.init(.{ .failure_threshold = 1, .cooldown_ns = 1_000 });

    const msgs = emptyMessages();

    try testing.expect(breaker.allow(0));
    const first = inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    try testing.expectError(error.Unavailable, first);
    breaker.recordFailure(0);
    try testing.expect(!breaker.allow(100));

    // After cooldown, breaker allows one trial; the next scripted step
    // is .pass, so the call succeeds.
    try testing.expect(breaker.allow(2_000));
    const resp = try inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("reply", resp.text.?);

    breaker.recordSuccess(2_000);
    try testing.expectEqual(llm.reliability.BreakerState.closed, breaker.state);
}
