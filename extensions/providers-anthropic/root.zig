//! Anthropic provider.
//!
//! Parses Anthropic's messages streaming format into a `ChatResponse`.
//! Bytes feeding the parser come from a `BytesSource` union with two
//! variants: `.literal` (cassette / unit-test bytes used verbatim) and
//! `.http` (a real POST against `/v1/messages` whose response body is
//! streamed into the same parser). The split keeps the SSE state
//! machine identical between the two paths so cassette tests remain
//! representative.
//!
//! Event surface covered:
//!
//!   message_start              ignored beyond usage
//!   content_block_start        ignored
//!   content_block_delta        text accumulated
//!   content_block_stop         ignored
//!   message_delta              stop_reason + usage
//!   message_stop               stream ends
//!   error                      surfaces as .refusal with detail message
//!
//! Anything else is silently skipped — the format has grown new event
//! types historically, and we'd rather ignore unknowns than refuse to
//! stream.
//!
//! Failure policy on the HTTP path: transport errors and non-2xx
//! responses are surfaced as a `ChatResponse` with `stop_reason =
//! .refusal` so the harness can decide whether to retry / fall back,
//! rather than bubbling typed errors past the provider boundary.

const std = @import("std");
const provider_mod = @import("llm_provider");
const transport = @import("llm_transport");
const types = @import("types");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

/// How the provider obtains the SSE byte stream.
pub const BytesSource = union(enum) {
    /// The parser consumes these bytes verbatim. Useful for tests and
    /// for cassette-backed replay.
    literal: []const u8,
    /// Drives the parser from a real Anthropic Messages API call.
    http: HttpSource,
};

/// Configuration for a live Anthropic Messages API call. Caller owns
/// every slice in here — the provider never frees them.
pub const HttpSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    /// Defaults to "https://api.anthropic.com/v1/messages" — overridable
    /// for tests that point at a mock server.
    endpoint: []const u8 = "https://api.anthropic.com/v1/messages",
    /// API version header. Default tracks the current stable release.
    api_version: []const u8 = "2023-06-01",
    /// Comma-separated `anthropic-beta` header values, or empty for none.
    /// Used to opt into prompt caching, etc.
    beta_features: []const u8 = "",
};

pub const AnthropicProvider = struct {
    source: BytesSource,

    pub fn init(source: BytesSource) AnthropicProvider {
        return .{ .source = source };
    }

    pub fn provider(self: *AnthropicProvider) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        switch (self.source) {
            .literal => |bytes| return parseStream(allocator, .{ .literal = bytes }),
            .http => |cfg| return runHttp(allocator, cfg, request),
        }
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
// Stream-driven parsing (shared by literal and http paths)

pub const StreamInput = union(enum) {
    /// All bytes are already in memory; feed once.
    literal: []const u8,
    /// Pull bytes incrementally from this reader until EOF.
    reader: *std.Io.Reader,
};

/// Callback fired once per text delta as the stream is decoded. Slice
/// is borrowed for the duration of the call only; copy if the sink
/// needs to outlive the callback. `ctx` carries caller state — the
/// gateway passes its SSE writer here so each token forwards to the
/// HTTP client without buffering the full reply first.
pub const TokenSink = *const fn (ctx: ?*anyopaque, token: []const u8) void;

fn parseStream(allocator: std.mem.Allocator, input: StreamInput) !ChatResponse {
    return parseStreamInner(allocator, input, null, null);
}

/// Same as the internal `parseStream` but invokes `sink(ctx, token)` for
/// every text delta seen on a `content_block_delta` event. The full
/// reply is still accumulated and returned in the final `ChatResponse`
/// so callers that only want streaming side effects can ignore it. On
/// an `error` event the sink is NOT invoked with the error message —
/// it still surfaces in `ChatResponse.text` as the final refusal.
pub fn streamTokens(
    allocator: std.mem.Allocator,
    input: StreamInput,
    sink: TokenSink,
    sink_ctx: ?*anyopaque,
) !ChatResponse {
    return parseStreamInner(allocator, input, sink, sink_ctx);
}

fn parseStreamInner(
    allocator: std.mem.Allocator,
    input: StreamInput,
    sink: ?TokenSink,
    sink_ctx: ?*anyopaque,
) !ChatResponse {
    var parser = transport.sse.Parser.init();
    defer parser.deinit(allocator);

    var text: std.array_list.Aligned(u8, null) = .empty;
    errdefer text.deinit(allocator);

    var usage = types.TokenUsage{};
    var stop: types.StopReason = .end_turn;
    var err_text: ?[]const u8 = null;
    defer if (err_text) |e| allocator.free(e);

    switch (input) {
        .literal => |bytes| try parser.feed(allocator, bytes),
        .reader => |r| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try r.readSliceShort(&buf);
                if (n == 0) break;
                try parser.feed(allocator, buf[0..n]);
            }
        },
    }

    while (try parser.nextEvent(allocator)) |ev| {
        if (std.mem.eql(u8, ev.name, "content_block_delta")) {
            const before = text.items.len;
            try absorbDelta(allocator, &text, ev.data);
            if (sink) |s| {
                const fragment = text.items[before..];
                if (fragment.len > 0) s(sink_ctx, fragment);
            }
        } else if (std.mem.eql(u8, ev.name, "message_delta")) {
            try absorbMessageDelta(&usage, &stop, ev.data);
        } else if (std.mem.eql(u8, ev.name, "message_start")) {
            try absorbMessageStart(&usage, ev.data);
        } else if (std.mem.eql(u8, ev.name, "error")) {
            stop = .refusal;
            err_text = try absorbError(allocator, ev.data);
        }
        // Unknown events: skip.
    }

    if (err_text) |e| {
        const owned = try allocator.dupe(u8, e);
        text.deinit(allocator);
        return .{
            .text = owned,
            .usage = usage,
            .stop_reason = .refusal,
        };
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .usage = usage,
        .stop_reason = stop,
    };
}

// ---------------------------------------------------------------------------
// HTTP path

fn runHttp(
    allocator: std.mem.Allocator,
    cfg: HttpSource,
    request: ChatRequest,
) !ChatResponse {
    const body = try buildRequestBody(allocator, request, 1024);
    defer allocator.free(body);

    // Anthropic OAuth tokens (sk-ant-oat01-...) speak the same Messages
    // endpoint but switch authentication: Bearer auth, ?beta=true on
    // the URL, anthropic-beta: oauth-2025-04-20, and a Claude CLI
    // user-agent. Standard sk-ant-api03- keys keep the x-api-key path.
    const is_oauth = std.mem.startsWith(u8, cfg.api_key, "sk-ant-oat01-");

    const oauth_url_buf_size = 256;
    var oauth_url_buf: [oauth_url_buf_size]u8 = undefined;
    const endpoint_str = if (is_oauth) blk: {
        const sep: u8 = if (std.mem.indexOfScalar(u8, cfg.endpoint, '?') != null) '&' else '?';
        const u = std.fmt.bufPrint(&oauth_url_buf, "{s}{c}beta=true", .{ cfg.endpoint, sep }) catch
            return refusal(allocator, "anthropic transport error: endpoint too long", .{});
        break :blk u;
    } else cfg.endpoint;

    const uri = std.Uri.parse(endpoint_str) catch
        return refusal(allocator, "anthropic transport error: invalid endpoint", .{});

    var client: std.http.Client = .{ .allocator = allocator, .io = cfg.io };
    defer client.deinit();

    var auth_buf: [512]u8 = undefined;
    var extra_buf: [6]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (is_oauth) {
        const v = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{cfg.api_key}) catch
            return refusal(allocator, "anthropic transport error: api_key too long", .{});
        extra_buf[extra_len] = .{ .name = "authorization", .value = v };
        extra_len += 1;
    } else {
        extra_buf[extra_len] = .{ .name = "x-api-key", .value = cfg.api_key };
        extra_len += 1;
    }
    extra_buf[extra_len] = .{ .name = "anthropic-version", .value = cfg.api_version };
    extra_len += 1;
    extra_buf[extra_len] = .{ .name = "content-type", .value = "application/json" };
    extra_len += 1;
    if (is_oauth) {
        extra_buf[extra_len] = .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" };
        extra_len += 1;
        extra_buf[extra_len] = .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" };
        extra_len += 1;
    } else if (cfg.beta_features.len > 0) {
        extra_buf[extra_len] = .{ .name = "anthropic-beta", .value = cfg.beta_features };
        extra_len += 1;
    }

    var req = client.request(.POST, uri, .{
        .keep_alive = false,
        .extra_headers = extra_buf[0..extra_len],
    }) catch |err| return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});
    defer req.deinit();

    var send_buf: [1024]u8 = undefined;
    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = req.sendBodyUnflushed(&send_buf) catch |err|
        return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});
    body_writer.writer.writeAll(body) catch |err|
        return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});
    body_writer.end() catch |err|
        return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});
    req.connection.?.flush() catch |err|
        return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});

    var redirect_buf: [256]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err|
        return refusal(allocator, "anthropic transport error: {s}", .{@errorName(err)});

    const status_code: u16 = @intFromEnum(response.head.status);
    if (status_code != 200) {
        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);

        var drained: std.array_list.Aligned(u8, null) = .empty;
        defer drained.deinit(allocator);

        var read_buf: [1024]u8 = undefined;
        while (drained.items.len < 1024) {
            const n = body_reader.readSliceShort(&read_buf) catch break;
            if (n == 0) break;
            const room = 1024 - drained.items.len;
            const take = @min(n, room);
            try drained.appendSlice(allocator, read_buf[0..take]);
            if (take < n) break;
        }

        return refusal(
            allocator,
            "anthropic api error: {d} {s}",
            .{ status_code, drained.items },
        );
    }

    // Anthropic's HTTP layer auto-negotiates Accept-Encoding so the
    // response body may arrive gzip- or zstd-compressed. Use the
    // `readerDecompressing` variant so the parser sees plain SSE
    // bytes regardless of what content-encoding the server picked.
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const body_reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    return parseStream(allocator, .{ .reader = body_reader });
}

/// Render the Anthropic-shaped JSON request body. Extracted so tests
/// can pin the wire format without exercising the HTTP client.
///
/// The system block always carries `cache_control: ephemeral` —
/// gateways are short-lived in v0.1.0, so longer cache TTLs aren't
/// worth the per-key bookkeeping yet.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    request: ChatRequest,
    max_tokens_default: u32,
) ![]u8 {
    var buf: std.array_list.Aligned(u8, null) = .empty;
    defer buf.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };

    try stringify.beginObject();

    try stringify.objectField("model");
    try stringify.write(request.model.model);

    try stringify.objectField("max_tokens");
    const max_tokens: u32 = request.max_output_tokens orelse max_tokens_default;
    try stringify.write(max_tokens);

    if (request.system) |sys_text| {
        try stringify.objectField("system");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("text");
        try stringify.objectField("text");
        try stringify.write(sys_text);
        try stringify.objectField("cache_control");
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("ephemeral");
        try stringify.endObject();
        try stringify.endObject();
        try stringify.endArray();
    }

    try stringify.objectField("messages");
    try stringify.beginArray();
    for (request.messages) |msg| {
        std.debug.assert(msg.role != .system);
        try stringify.beginObject();
        try stringify.objectField("role");
        switch (msg.role) {
            .user, .tool => try stringify.write("user"),
            .assistant => try stringify.write("assistant"),
            .system => unreachable,
        }
        try stringify.objectField("content");
        try stringify.beginArray();
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("text");
        try stringify.objectField("text");
        try stringify.write(msg.content);
        try stringify.endObject();
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.objectField("stream");
    try stringify.write(true);

    try stringify.objectField("temperature");
    try stringify.write(request.temperature);

    try stringify.endObject();

    return aw.toOwnedSlice();
}

fn refusal(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !ChatResponse {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    return .{
        .text = text,
        .usage = .{},
        .stop_reason = .refusal,
    };
}

// ---------------------------------------------------------------------------
// Event parsers

fn absorbDelta(
    allocator: std.mem.Allocator,
    out: *std.array_list.Aligned(u8, null),
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    const delta = root.object.get("delta") orelse return;
    const kind = delta.object.get("type") orelse return;
    if (kind != .string) return;
    if (!std.mem.eql(u8, kind.string, "text_delta")) return;
    const text = delta.object.get("text") orelse return;
    if (text != .string) return;
    try out.appendSlice(allocator, text.string);
}

fn absorbMessageDelta(
    usage: *types.TokenUsage,
    stop: *types.StopReason,
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;

    if (root.object.get("delta")) |delta| {
        if (delta.object.get("stop_reason")) |sr| {
            if (sr == .string) {
                if (std.mem.eql(u8, sr.string, "end_turn")) stop.* = .end_turn;
                if (std.mem.eql(u8, sr.string, "max_tokens")) stop.* = .max_tokens;
                if (std.mem.eql(u8, sr.string, "tool_use")) stop.* = .tool_use;
                if (std.mem.eql(u8, sr.string, "stop_sequence")) stop.* = .stop_sequence;
            }
        }
    }
    if (root.object.get("usage")) |u| {
        absorbUsage(usage, u);
    }
}

fn absorbMessageStart(usage: *types.TokenUsage, data: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    const msg = root.object.get("message") orelse return;
    if (msg.object.get("usage")) |u| absorbUsage(usage, u);
}

fn absorbUsage(usage: *types.TokenUsage, u: std.json.Value) void {
    if (u != .object) return;
    if (u.object.get("input_tokens")) |v| if (v == .integer) {
        usage.input = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("output_tokens")) |v| if (v == .integer) {
        usage.output = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("cache_read_input_tokens")) |v| if (v == .integer) {
        usage.cache_read = @intCast(@max(v.integer, 0));
    };
    if (u.object.get("cache_creation_input_tokens")) |v| if (v == .integer) {
        usage.cache_write = @intCast(@max(v.integer, 0));
    };
}

fn absorbError(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const err = parsed.value.object.get("error") orelse return null;
    const msg = err.object.get("message") orelse return null;
    if (msg != .string) return null;
    return try allocator.dupe(u8, msg.string);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn makeProvider(source: BytesSource) AnthropicProvider {
    return AnthropicProvider.init(source);
}

test "anthropic: assembles text from content_block_delta events" {
    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\", world\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("Hello, world", resp.text.?);
    try testing.expectEqual(@as(u32, 10), resp.usage.input);
    try testing.expectEqual(@as(u32, 3), resp.usage.output);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "anthropic: unknown event types are ignored" {
    const stream =
        "event: ping\ndata: {}\n\n" ++
        "event: content_block_delta\ndata: {\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "event: totally_unknown\ndata: {\"whatever\":1}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("hi", resp.text.?);
}

test "anthropic: error frame surfaces as refusal with detail" {
    const stream =
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Upstream busy\"}}\n\n";

    var p = makeProvider(.{ .literal = stream });
    const provider = p.provider();

    const msgs = [_]types.Message{};
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.refusal, resp.stop_reason);
    try testing.expectEqualStrings("Upstream busy", resp.text.?);
}

test "anthropic: stop_reason variants map correctly" {
    const cases = [_]struct { marker: []const u8, expected: types.StopReason }{
        .{ .marker = "end_turn", .expected = .end_turn },
        .{ .marker = "max_tokens", .expected = .max_tokens },
        .{ .marker = "tool_use", .expected = .tool_use },
        .{ .marker = "stop_sequence", .expected = .stop_sequence },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        const stream = try std.fmt.bufPrint(
            &buf,
            "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}}}\n\n",
            .{c.marker},
        );

        var p = makeProvider(.{ .literal = stream });
        const provider = p.provider();

        const msgs = [_]types.Message{};
        const resp = try provider.chat(testing.allocator, .{
            .messages = &msgs,
            .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
        });
        defer if (resp.text) |t| testing.allocator.free(t);

        try testing.expectEqual(c.expected, resp.stop_reason);
    }
}

test "anthropic: supportsNativeTools is true" {
    var p = makeProvider(.{ .literal = "" });
    const provider = p.provider();
    try testing.expect(provider.supportsNativeTools());
    try testing.expectEqualStrings("anthropic", provider.name());
}

test "anthropic: buildRequestBody renders canonical wire shape" {
    const messages = [_]types.Message{
        .{ .role = .user, .content = "hi there" },
    };
    const req: ChatRequest = .{
        .messages = &messages,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
        .system = "be brief",
    };

    const body = try buildRequestBody(testing.allocator, req, 1024);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"hi there\"}]") != null);
    // Loose match: avoid coupling to f32 → JSON formatting precision.
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.6") != null);
}

const ServerArgs = struct {
    io: std.Io,
    server: *std.Io.net.Server,
};

fn serveOne401(args: *ServerArgs) void {
    var stream = args.server.accept(args.io) catch return;
    defer stream.close(args.io);
    var write_buf: [256]u8 = undefined;
    var w = stream.writer(args.io, &write_buf);
    _ = w.interface.writeAll(
        "HTTP/1.1 401 Unauthorized\r\ncontent-length: 16\r\nconnection: close\r\n\r\n{\"error\":\"oops\"}",
    ) catch {};
    _ = w.interface.flush() catch {};
}

test "anthropic: http error path surfaces refusal" {
    const probe_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try probe_addr.listen(testing.io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();

    var args: ServerArgs = .{ .io = testing.io, .server = &server };
    const thread = try std.Thread.spawn(.{}, serveOne401, .{&args});
    defer {
        thread.join();
        server.deinit(testing.io);
    }

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/messages", .{port});

    var p = makeProvider(.{ .http = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .api_key = "sk-test",
        .endpoint = url,
    } });
    const provider = p.provider();

    const msgs = [_]types.Message{
        .{ .role = .user, .content = "hello" },
    };
    const resp = try provider.chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "anthropic", .model = "claude-opus-4-7" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.refusal, resp.stop_reason);
    try testing.expect(resp.text != null);
    try testing.expect(std.mem.indexOf(u8, resp.text.?, "401") != null);
}

const TokenCollector = struct {
    fragments: std.array_list.Aligned([]u8, null) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *TokenCollector) void {
        for (self.fragments.items) |f| self.allocator.free(f);
        self.fragments.deinit(self.allocator);
    }

    fn appendCb(ctx: ?*anyopaque, token: []const u8) void {
        const self: *TokenCollector = @ptrCast(@alignCast(ctx.?));
        const owned = self.allocator.dupe(u8, token) catch return;
        self.fragments.append(self.allocator, owned) catch {
            self.allocator.free(owned);
        };
    }
};

test "anthropic: streamTokens fires sink per content_block_delta and accumulates final text" {
    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo \"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    var collector: TokenCollector = .{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try streamTokens(
        testing.allocator,
        .{ .literal = stream },
        TokenCollector.appendCb,
        &collector,
    );
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(@as(usize, 3), collector.fragments.items.len);
    try testing.expectEqualStrings("Hel", collector.fragments.items[0]);
    try testing.expectEqualStrings("lo ", collector.fragments.items[1]);
    try testing.expectEqualStrings("world", collector.fragments.items[2]);

    try testing.expectEqualStrings("Hello world", resp.text.?);
    try testing.expectEqual(@as(u32, 7), resp.usage.input);
    try testing.expectEqual(@as(u32, 3), resp.usage.output);
    try testing.expectEqual(types.StopReason.end_turn, resp.stop_reason);
}

test "anthropic: streamTokens does not invoke sink on error events" {
    const stream =
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"slow down\"}}\n\n";

    var collector: TokenCollector = .{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try streamTokens(
        testing.allocator,
        .{ .literal = stream },
        TokenCollector.appendCb,
        &collector,
    );
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(@as(usize, 0), collector.fragments.items.len);
    try testing.expectEqual(types.StopReason.refusal, resp.stop_reason);
    try testing.expect(resp.text != null);
    try testing.expect(std.mem.indexOf(u8, resp.text.?, "slow down") != null);
}
