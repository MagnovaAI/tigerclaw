//! Integration: route requests across three concrete providers.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const llm = tigerclaw.llm;

const testing = std.testing;

const anthropic_stream =
    "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"from-anthropic\"}}\n\n" ++
    "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n";

const openai_stream =
    "data: {\"choices\":[{\"delta\":{\"content\":\"from-openai\"}}]}\n\n" ++
    "data: [DONE]\n\n";

fn emptyMessages() [0]tigerclaw.types.Message {
    return .{};
}

test "router: request for anthropic lands on the anthropic provider" {
    var anth = llm.providers.AnthropicProvider.init(.{ .literal = anthropic_stream });
    var oai = llm.providers.OpenAIProvider.init(.{ .literal = openai_stream });

    const routes = [_]llm.routing.Route{
        .{ .name = "anthropic", .provider = anth.provider() },
        .{ .name = "openai", .provider = oai.provider() },
    };
    const anth_chain = [_][]const u8{"anthropic"};
    const policy = llm.routing.Policy{
        .rules = &.{
            .{ .request_provider = "anthropic", .fallback_chain = &anth_chain },
        },
    };
    const router = llm.Router.init(&routes, policy);

    const msgs = emptyMessages();
    const resp = try router.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("from-anthropic", resp.text.?);
}

test "router: fallback chain picks openai when anthropic fails retryably" {
    // An exhausted mock fails with error.MockExhausted (retryable).
    const empty_mock_replies = [_]llm.providers.mock.Reply{};
    var exhausted = llm.MockProvider{ .replies = &empty_mock_replies };
    var oai = llm.providers.OpenAIProvider.init(.{ .literal = openai_stream });

    const routes = [_]llm.routing.Route{
        .{ .name = "primary", .provider = exhausted.provider() },
        .{ .name = "backup", .provider = oai.provider() },
    };
    const chain = [_][]const u8{ "primary", "backup" };
    const policy = llm.routing.Policy{
        .rules = &.{
            .{ .request_provider = "anthropic", .fallback_chain = &chain },
        },
    };
    const router = llm.Router.init(&routes, policy);

    const msgs = emptyMessages();
    const resp = try router.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("from-openai", resp.text.?);
}

test "router: unmatched request provider + empty default → NoProvider" {
    const routes = [_]llm.routing.Route{};
    const policy = llm.routing.Policy{ .rules = &.{} };
    const router = llm.Router.init(&routes, policy);

    const msgs = emptyMessages();
    try testing.expectError(
        error.NoProvider,
        router.chat(testing.allocator, .{
            .messages = &msgs,
            .model = .{ .provider = "never", .model = "x" },
        }),
    );
}
