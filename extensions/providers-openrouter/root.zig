//! OpenRouter provider — OpenAI-compatible aggregator.
//!
//! OpenRouter exposes a chat-completions endpoint that is wire-compatible
//! with OpenAI's: same JSON request shape, same SSE event format
//! (`data: {...}\n\n` chunks terminated by `data: [DONE]`). The whole
//! point of OpenRouter is to route to dozens of upstream providers
//! through a single API key and a single billing account, so this
//! provider intentionally passes the model string straight through —
//! callers ask for `"anthropic/claude-3.5-sonnet"`, `"openai/gpt-4o"`,
//! `"meta-llama/llama-3.1-70b-instruct"`, etc., and OpenRouter handles
//! the rest. No whitelist, no rewriting, no validation.
//!
//! Because the wire format is identical, the SSE parser and chunk
//! absorption logic mirror the OpenAI provider. The differences are:
//!
//!   - Endpoint: `https://openrouter.ai/api/v1/chat/completions`.
//!   - Optional `HTTP-Referer` / `X-Title` headers OpenRouter consumes
//!     for app-attribution analytics; both are caller-supplied and
//!     omitted by default.
//!   - Bytes can come from a `.literal` source (test/cassette replay)
//!     or from `.http` which streams a real chat completion via
//!     `std.http.Client.request` and feeds the response body into the
//!     SSE parser as it arrives.
//!
//! Non-2xx responses are surfaced as `ChatResponse{ .stop_reason =
//! .refusal, .text = "openrouter api error: <status> <body>" }` with
//! the body capped to keep refusal text small. Transport-level errors
//! collapse into the same refusal shape with the error name in place
//! of the body.

const std = @import("std");
const provider_mod = @import("llm_provider");
const transport = @import("llm_transport");
const types = @import("types");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

/// Soft cap on the body bytes preserved in a refusal. OpenRouter's
/// error payloads are short JSON objects; 1 KiB is more than enough to
/// preserve the message without dragging huge HTML fallback pages into
/// a `ChatResponse.text` value.
const max_error_body_bytes: usize = 1024;

/// Default `max_tokens` when the caller does not supply one. Mirrors
/// the rest of the harness — a deliberately small cap so accidental
/// runs do not blow through the budget.
const default_max_tokens: u32 = 1024;

pub const HttpSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    /// Override only when pointing at a local fake (tests) or a self-
    /// hosted gateway. Defaults to the public OpenRouter endpoint.
    endpoint: []const u8 = "https://openrouter.ai/api/v1/chat/completions",
    /// Optional `HTTP-Referer` header. OpenRouter shows this on the
    /// activity dashboard so an app can attribute its own traffic.
    /// Caller-owned slice; the provider does not copy it.
    http_referer: ?[]const u8 = null,
    /// Optional `X-Title` header. Same purpose as `http_referer` — an
    /// app-friendly display name shown next to the request in the
    /// OpenRouter dashboard. Caller-owned.
    app_title: ?[]const u8 = null,
};

pub const BytesSource = union(enum) {
    /// The parser consumes these bytes verbatim. Used by tests and by
    /// VCR-cassette replay.
    literal: []const u8,
    /// Issue a real chat completion over HTTP and stream the response
    /// body through the SSE parser.
    http: HttpSource,
};

pub const OpenRouterProvider = struct {
    source: BytesSource,

    pub fn init(source: BytesSource) OpenRouterProvider {
        return .{ .source = source };
    }

    pub fn provider(self: *OpenRouterProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openrouter";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *OpenRouterProvider = @ptrCast(@alignCast(ptr));
        return switch (self.source) {
            .literal => |bytes| try parseStream(allocator, bytes),
            .http => |cfg| try doHttpChat(allocator, cfg, request),
        };
    }

    fn supportsTools(_: *anyopaque) bool {
        return true;
    }

    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
};

// ---------------------------------------------------------------------------
// Request body builder

/// Renders the JSON body OpenRouter expects. Extracted so tests can
/// assert on the wire shape without needing a real HTTP server.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    request: ChatRequest,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    try s.objectField("model");
    try s.write(request.model.model);

    try s.objectField("messages");
    try s.beginArray();
    // OpenAI / OpenRouter expect the system prompt as the first entry
    // of the `messages` array (no separate top-level field). Emit it
    // when the caller supplied one; without this, the agent's SOUL.md
    // persona is silently dropped and the model falls back to its
    // stock identity.
    if (request.system) |sys_text| {
        if (sys_text.len > 0) {
            try s.beginObject();
            try s.objectField("role");
            try s.write("system");
            try s.objectField("content");
            try s.write(sys_text);
            try s.endObject();
        }
    }
    for (request.messages) |msg| {
        if (msg.content.len == 0) continue;
        try writeOpenAIMessage(allocator, &s, msg);
    }
    try s.endArray();

    try s.objectField("stream");
    try s.write(true);

    try s.objectField("max_tokens");
    try s.write(request.max_output_tokens orelse default_max_tokens);

    // Temperature is always set in `ChatRequest` (default 0.7), so we
    // always emit it. The skill's "omit if null" guidance refers to
    // optional caller intent; the upstream type carries a concrete
    // value, which we forward verbatim.
    try s.objectField("temperature");
    try s.write(request.temperature);

    try s.endObject();

    return aw.toOwnedSlice();
}

/// Serialize one Message in OpenAI/OpenRouter chat-completions wire
/// format. Differs from Anthropic in three structural ways:
///   * `tool_use` blocks become an `assistant` message's `tool_calls`
///     array (alongside any `content` text);
///   * `tool_result` blocks are emitted as separate `role:tool`
///     messages (one per result), each carrying `tool_call_id` and
///     a stringified `content` field;
///   * if the assistant emitted only a `tool_use` (no text),
///     `content` is null rather than an empty string.
fn writeOpenAIMessage(
    allocator: std.mem.Allocator,
    s: *std.json.Stringify,
    msg: types.Message,
) !void {
    // Walk blocks once to classify what's present.
    var text_combined: ?[]const u8 = null;
    var first_tool_use_idx: ?usize = null;
    var first_tool_result_idx: ?usize = null;
    var any_tool_use = false;
    var any_tool_result = false;
    for (msg.content, 0..) |b, i| {
        switch (b) {
            .text => |t| {
                if (text_combined == null) text_combined = t;
                // For multi-text-block messages we'd need to
                // concatenate; leave that to a future refactor —
                // today the runner only ever emits one text block
                // per message.
            },
            .tool_use => {
                if (first_tool_use_idx == null) first_tool_use_idx = i;
                any_tool_use = true;
            },
            .tool_result => {
                if (first_tool_result_idx == null) first_tool_result_idx = i;
                any_tool_result = true;
            },
        }
    }

    if (any_tool_result) {
        // Emit one `role:tool` message per tool_result block.
        // Multiple tool results from a single batch fan out into
        // multiple wire messages — the role itself can't ride
        // tool_calls and content together in OpenAI's format.
        for (msg.content) |b| {
            switch (b) {
                .tool_result => |tr| {
                    try s.beginObject();
                    try s.objectField("role");
                    try s.write("tool");
                    try s.objectField("tool_call_id");
                    try s.write(tr.tool_use_id);
                    try s.objectField("content");
                    try s.write(tr.content);
                    try s.endObject();
                },
                else => {},
            }
        }
        return;
    }

    // Non-tool_result message: emit as a single object.
    try s.beginObject();
    try s.objectField("role");
    try s.write(@tagName(msg.role));

    // Content: text if present, else null when tool_calls only.
    try s.objectField("content");
    if (text_combined) |t| {
        try s.write(t);
    } else {
        try s.write(null);
    }

    if (any_tool_use) {
        try s.objectField("tool_calls");
        try s.beginArray();
        for (msg.content) |b| {
            switch (b) {
                .tool_use => |tu| {
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(tu.id);
                    try s.objectField("type");
                    try s.write("function");
                    try s.objectField("function");
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(tu.name);
                    try s.objectField("arguments");
                    // OpenAI expects `arguments` as a JSON string,
                    // not an object — pass the already-encoded JSON
                    // through verbatim. Empty args become "{}".
                    try s.write(if (tu.input_json.len == 0) "{}" else tu.input_json);
                    try s.endObject();
                    try s.endObject();
                },
                else => {},
            }
        }
        try s.endArray();
    }
    try s.endObject();
    _ = allocator;
}

// ---------------------------------------------------------------------------
// HTTP path

fn doHttpChat(
    allocator: std.mem.Allocator,
    cfg: HttpSource,
    request: ChatRequest,
) !ChatResponse {
    const body = try buildRequestBody(allocator, request);
    defer allocator.free(body);

    return performHttp(allocator, cfg, body) catch |err| {
        return refusalFromTransport(allocator, err);
    };
}

fn performHttp(
    allocator: std.mem.Allocator,
    cfg: HttpSource,
    body: []const u8,
) !ChatResponse {
    var client: std.http.Client = .{ .allocator = cfg.allocator, .io = cfg.io };
    defer client.deinit();

    const uri = try std.Uri.parse(cfg.endpoint);

    var auth_buf: [512]u8 = undefined;
    const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{cfg.api_key});

    var headers_buf: [4]std.http.Header = undefined;
    var headers_len: usize = 0;
    headers_buf[headers_len] = .{ .name = "authorization", .value = auth_value };
    headers_len += 1;
    headers_buf[headers_len] = .{ .name = "content-type", .value = "application/json" };
    headers_len += 1;
    if (cfg.http_referer) |ref| {
        headers_buf[headers_len] = .{ .name = "HTTP-Referer", .value = ref };
        headers_len += 1;
    }
    if (cfg.app_title) |title| {
        headers_buf[headers_len] = .{ .name = "X-Title", .value = title };
        headers_len += 1;
    }

    var req = try client.request(.POST, uri, .{
        .keep_alive = false,
        .extra_headers = headers_buf[0..headers_len],
    });
    defer req.deinit();

    // `sendBodyComplete` mutates the buffer in place (it routes through
    // the body writer); the bytes are immutable to the caller, but the
    // API takes a `[]u8`, so we hand it a fresh dupe we own.
    const send_buf = try allocator.dupe(u8, body);
    defer allocator.free(send_buf);
    try req.sendBodyComplete(send_buf);

    var redirect_buf: [4 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    const code: u16 = @intFromEnum(response.head.status);

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    if (code < 200 or code >= 300) {
        return refusalFromHttp(allocator, code, reader);
    }

    return drainStream(allocator, reader);
}

fn drainStream(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ChatResponse {
    var collected: std.Io.Writer.Allocating = .init(allocator);
    defer collected.deinit();

    // `streamRemaining` returns once the underlying body reader reports
    // EOF, surfacing only ReadFailed/WriteFailed. A WriteFailed against
    // an `Allocating` writer would mean OOM, which we propagate.
    _ = try reader.streamRemaining(&collected.writer);

    return parseStream(allocator, collected.written());
}

fn refusalFromHttp(
    allocator: std.mem.Allocator,
    status: u16,
    reader: *std.Io.Reader,
) !ChatResponse {
    var body_buf: [max_error_body_bytes]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);
    // `WriteFailed` fires when the body exceeds our cap; both that and
    // `ReadFailed` leave whatever was buffered intact, which is what we
    // want to render in the refusal text.
    _ = reader.streamRemaining(&body_writer) catch {};

    const text = try std.fmt.allocPrint(
        allocator,
        "openrouter api error: {d} {s}",
        .{ status, body_writer.buffered() },
    );
    return .{
        .text = text,
        .usage = .{},
        .stop_reason = .refusal,
    };
}

fn refusalFromTransport(allocator: std.mem.Allocator, err: anyerror) !ChatResponse {
    const text = try std.fmt.allocPrint(
        allocator,
        "openrouter transport error: {s}",
        .{@errorName(err)},
    );
    return .{
        .text = text,
        .usage = .{},
        .stop_reason = .refusal,
    };
}

// ---------------------------------------------------------------------------
// SSE parser — shared shape with the OpenAI provider.

fn parseStream(allocator: std.mem.Allocator, bytes: []const u8) !ChatResponse {
    var parser = transport.sse.Parser.init();
    defer parser.deinit(allocator);
    try parser.feed(allocator, bytes);

    var text: std.array_list.Aligned(u8, null) = .empty;
    errdefer text.deinit(allocator);

    var usage = types.TokenUsage{};
    var stop: types.StopReason = .end_turn;

    while (try parser.nextEvent(allocator)) |ev| {
        if (std.mem.eql(u8, ev.data, "[DONE]")) break;
        try absorbChunk(allocator, &text, &usage, &stop, ev.data);
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .usage = usage,
        .stop_reason = stop,
    };
}

fn absorbChunk(
    allocator: std.mem.Allocator,
    out: *std.array_list.Aligned(u8, null),
    usage: *types.TokenUsage,
    stop: *types.StopReason,
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first.object.get("delta")) |delta| {
                if (delta.object.get("content")) |c| {
                    if (c == .string) try out.appendSlice(allocator, c.string);
                }
            }
            if (first.object.get("finish_reason")) |fr| {
                if (fr == .string) stop.* = mapFinishReason(fr.string);
            }
        }
    }
    if (root.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| if (v == .integer) {
                usage.input = @intCast(@max(v.integer, 0));
            };
            if (u.object.get("completion_tokens")) |v| if (v == .integer) {
                usage.output = @intCast(@max(v.integer, 0));
            };
        }
    }
}

fn mapFinishReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .end_turn;
    if (std.mem.eql(u8, reason, "length")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .refusal;
    return .end_turn;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "openrouter: name and native tools" {
    var p = OpenRouterProvider.init(.{ .literal = "" });
    const provider = p.provider();
    try testing.expectEqualStrings("openrouter", provider.name());
    try testing.expect(provider.supportsNativeTools());
}

test "openrouter: assembles content across chunks" {
    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\", world\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";

    var p = OpenRouterProvider.init(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "anthropic/claude-3.5-sonnet" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("Hello, world", resp.text.?);
    try testing.expectEqual(@as(u32, 5), resp.usage.input);
    try testing.expectEqual(@as(u32, 3), resp.usage.output);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "openrouter: buildRequestBody preserves model string and shape" {
    const msgs = [_]types.Message{
        types.Message.literal(.system, "be terse"),
        types.Message.literal(.user, "hi"),
    };
    const req: ChatRequest = .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "anthropic/claude-3.5-sonnet" },
    };

    const body = try buildRequestBody(testing.allocator, req);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"anthropic/claude-3.5-sonnet\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"be terse\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
}

test "scenario: buildRequestBody promotes ChatRequest.system to the first messages entry" {
    // Regression for the session where sage and bolt agents answered
    // with their provider's default identity instead of their
    // SOUL.md persona. The runner sets `ChatRequest.system`; an
    // OpenAI-compatible body must surface that as a `{role: system}`
    // message at the head of `messages[]` or the persona is lost.
    const msgs = [_]types.Message{
        types.Message.literal(.user, "who are you"),
    };
    const req: ChatRequest = .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "openai/gpt-4o" },
        .system = "You are sage — a wise, patient agent.",
    };

    const body = try buildRequestBody(testing.allocator, req);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 2), messages.array.items.len);
    try testing.expectEqualStrings("system", messages.array.items[0].object.get("role").?.string);
    try testing.expectEqualStrings(
        "You are sage — a wise, patient agent.",
        messages.array.items[0].object.get("content").?.string,
    );
    try testing.expectEqualStrings("user", messages.array.items[1].object.get("role").?.string);
}

test "scenario: buildRequestBody omits the system entry when request.system is null" {
    const msgs = [_]types.Message{types.Message.literal(.user, "hi")};
    const req: ChatRequest = .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "openai/gpt-4o" },
    };

    const body = try buildRequestBody(testing.allocator, req);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 1), messages.array.items.len);
    try testing.expectEqualStrings("user", messages.array.items[0].object.get("role").?.string);
}

test "openrouter: buildRequestBody honours caller-provided max_tokens" {
    const msgs = [_]types.Message{
        types.Message.literal(.user, "x"),
    };
    const req: ChatRequest = .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "openai/gpt-4o" },
        .max_output_tokens = 42,
    };

    const body = try buildRequestBody(testing.allocator, req);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":42") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"openai/gpt-4o\"") != null);
}

const FakeServerArgs = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
};

fn fakeServerThread(args: *FakeServerArgs) void {
    var stream = args.server.accept(args.io) catch return;
    defer stream.close(args.io);

    // Use std.http.Server so request framing is parsed correctly — the
    // client will not finish its POST until the server has read the
    // head, and a hand-rolled raw write would deadlock if the response
    // arrived before the body fully flushed.
    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var s_reader = stream.reader(args.io, &read_buf);
    var s_writer = stream.writer(args.io, &write_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond(args.body, .{
        .status = args.status,
        .keep_alive = false,
    }) catch return;
}

test "openrouter: HTTP error path returns a refusal containing the status" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .payment_required,
        .body = "{\"error\":\"out_of_credits\"}",
    };

    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&args});
    defer thread.join();

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{port},
    );

    var p = OpenRouterProvider.init(.{ .http = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .api_key = "test-key",
        .endpoint = url,
    } });
    const provider = p.provider();

    const msgs = [_]types.Message{
        types.Message.literal(.user, "hello"),
    };
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "openrouter", .model = "openai/gpt-4o" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.refusal, resp.stop_reason);
    try testing.expect(std.mem.indexOf(u8, resp.text.?, "402") != null);
}
