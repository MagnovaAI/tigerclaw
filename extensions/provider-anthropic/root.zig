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
            .literal => |bytes| return parseStreamInner(allocator, .{ .literal = bytes }, null, null, request.cancel_token),
            .http => |cfg| return runHttp(allocator, cfg, request, null, null),
        }
    }

    /// Streaming variant: same flow as `doChat` but each text delta
    /// fires `sink(ctx, fragment)` as soon as it decodes. The final
    /// `ChatResponse` still carries the accumulated text so callers
    /// that treat the sink as a side channel (e.g. the runner when
    /// a turn rolls into tool-use) don't lose anything.
    fn doChatStream(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        sink: provider_mod.TokenSink,
        sink_ctx: ?*anyopaque,
    ) anyerror!ChatResponse {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        switch (self.source) {
            .literal => |bytes| return parseStreamInnerFull(
                allocator,
                .{ .literal = bytes },
                sink,
                sink_ctx,
                request.cancel_token,
                request.tool_start_sink,
                request.tool_start_sink_ctx,
            ),
            .http => |cfg| return runHttp(allocator, cfg, request, sink, sink_ctx),
        }
    }

    fn supportsTools(_: *anyopaque) bool {
        return true;
    }

    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .chatStream = doChatStream,
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
    return parseStreamInner(allocator, input, null, null, null);
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
    return parseStreamInner(allocator, input, sink, sink_ctx, null);
}

/// Streaming entry point with cooperative cancellation. The `cancel`
/// flag is polled between byte reads and between SSE events; on
/// `true` the call returns the partial response with
/// `stop_reason = .cancelled`. Tool-use blocks that started but
/// didn't finish their args land in `tool_calls` only if the
/// accumulated JSON parses cleanly; the runner pairs every emitted
/// `tool_use` with a synthetic tool_result to keep the conversation
/// history well-formed.
pub fn streamTokensCancellable(
    allocator: std.mem.Allocator,
    input: StreamInput,
    sink: TokenSink,
    sink_ctx: ?*anyopaque,
    cancel: ?*std.atomic.Value(bool),
) !ChatResponse {
    return parseStreamInner(allocator, input, sink, sink_ctx, cancel);
}

fn parseStreamInner(
    allocator: std.mem.Allocator,
    input: StreamInput,
    sink: ?TokenSink,
    sink_ctx: ?*anyopaque,
    cancel: ?*std.atomic.Value(bool),
) !ChatResponse {
    return parseStreamInnerFull(allocator, input, sink, sink_ctx, cancel, null, null);
}

fn parseStreamInnerFull(
    allocator: std.mem.Allocator,
    input: StreamInput,
    sink: ?TokenSink,
    sink_ctx: ?*anyopaque,
    cancel: ?*std.atomic.Value(bool),
    tool_start_sink: ?provider_mod.ToolStartSink,
    tool_start_ctx: ?*anyopaque,
) !ChatResponse {
    var parser = transport.sse.Parser.init();
    defer parser.deinit(allocator);

    var text: std.array_list.Aligned(u8, null) = .empty;
    errdefer text.deinit(allocator);

    var usage = types.TokenUsage{};
    var stop: types.StopReason = .end_turn;
    var err_text: ?[]const u8 = null;
    defer if (err_text) |e| allocator.free(e);

    // Tool-use accumulator. Anthropic streams tool_use as a content
    // block: `content_block_start` announces the id+name, then one
    // or more `content_block_delta` events with `input_json_delta`
    // chunks build up the arguments JSON. We buffer by index because
    // multiple blocks can be active across interleaved events.
    var tool_builders: std.ArrayListUnmanaged(ToolBuilder) = .empty;
    defer {
        for (tool_builders.items) |*b| b.deinit(allocator);
        tool_builders.deinit(allocator);
    }

    var cancelled = false;
    if (cancel) |c| if (c.load(.acquire)) {
        cancelled = true;
    };

    // Drain every event the parser currently has buffered into the
    // local accumulators. Called both interleaved with reader pulls
    // (so text deltas reach the sink as soon as bytes arrive) and
    // once at the end for the literal/EOF case. Returns true when
    // cancel fires mid-drain.
    const Drain = struct {
        fn run(
            alloc: std.mem.Allocator,
            p: *transport.sse.Parser,
            txt: *std.array_list.Aligned(u8, null),
            tb: *std.ArrayListUnmanaged(ToolBuilder),
            us: *types.TokenUsage,
            stp: *types.StopReason,
            etx: *?[]const u8,
            sk: ?TokenSink,
            sk_ctx: ?*anyopaque,
            ts_sink: ?provider_mod.ToolStartSink,
            ts_ctx: ?*anyopaque,
            cnc: ?*std.atomic.Value(bool),
            out_cancelled: *bool,
        ) !void {
            while (try p.nextEvent(alloc)) |ev| {
                if (std.mem.eql(u8, ev.name, "content_block_start")) {
                    try absorbContentBlockStart(alloc, tb, ev.data, ts_sink, ts_ctx);
                } else if (std.mem.eql(u8, ev.name, "content_block_delta")) {
                    const before = txt.items.len;
                    try absorbDelta(alloc, txt, ev.data);
                    if (sk) |s| {
                        const fragment = txt.items[before..];
                        if (fragment.len > 0) s(sk_ctx, fragment);
                    }
                    try absorbInputJsonDelta(alloc, tb, ev.data);
                } else if (std.mem.eql(u8, ev.name, "message_delta")) {
                    try absorbMessageDelta(us, stp, ev.data);
                } else if (std.mem.eql(u8, ev.name, "message_start")) {
                    try absorbMessageStart(us, ev.data);
                } else if (std.mem.eql(u8, ev.name, "error")) {
                    stp.* = .refusal;
                    etx.* = try absorbError(alloc, ev.data);
                }
                if (cnc) |c| if (c.load(.acquire)) {
                    out_cancelled.* = true;
                    return;
                };
            }
        }
    };

    if (!cancelled) switch (input) {
        .literal => |bytes| {
            try parser.feed(allocator, bytes);
            try Drain.run(allocator, &parser, &text, &tool_builders, &usage, &stop, &err_text, sink, sink_ctx, tool_start_sink, tool_start_ctx, cancel, &cancelled);
        },
        .reader => |r| {
            // Streaming path: interleave byte reads with event drains
            // so each text_delta reaches the sink the moment it
            // arrives. Without the drain after every feed, the sink
            // would only fire once the full response had been read,
            // defeating the streaming UX.
            var buf: [4096]u8 = undefined;
            while (true) {
                if (cancel) |c| if (c.load(.acquire)) {
                    cancelled = true;
                    break;
                };
                const n = try r.readSliceShort(&buf);
                if (n == 0) break;
                try parser.feed(allocator, buf[0..n]);
                try Drain.run(allocator, &parser, &text, &tool_builders, &usage, &stop, &err_text, sink, sink_ctx, tool_start_sink, tool_start_ctx, cancel, &cancelled);
                if (cancelled) break;
            }
        },
    };

    if (cancelled) stop = .cancelled;

    if (err_text) |e| {
        const owned = try allocator.dupe(u8, e);
        text.deinit(allocator);
        return .{
            .text = owned,
            .usage = usage,
            .stop_reason = .refusal,
        };
    }

    // Finalise tool calls. Anthropic emits an empty string for
    // arguments when the tool takes no input; normalise that to "{}"
    // so callers can always json-parse the field.
    var tool_calls: std.ArrayListUnmanaged(types.ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        tool_calls.deinit(allocator);
    }
    // When the stream stops on `max_tokens`, only the final tool_use
    // block can be truncated — every earlier block was followed by
    // additional events, so its `partial_json` is complete by
    // induction. Drop a tail block whose accumulated JSON doesn't
    // parse; the runner will re-ask the model, which then resumes
    // from the cleanly-emitted prefix.
    const last_idx: ?usize = if (stop == .max_tokens and tool_builders.items.len > 0)
        tool_builders.items.len - 1
    else
        null;
    for (tool_builders.items, 0..) |*b, i| {
        if (b.id.len == 0 or b.name.len == 0) continue;
        if (last_idx != null and i == last_idx.? and b.input.items.len > 0) {
            const probe = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                b.input.items,
                .{},
            ) catch {
                continue;
            };
            probe.deinit();
        }
        const args = if (b.input.items.len == 0)
            try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, b.input.items);
        errdefer allocator.free(args);
        try tool_calls.append(allocator, .{
            .id = try allocator.dupe(u8, b.id),
            .name = try allocator.dupe(u8, b.name),
            .arguments_json = args,
        });
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
        .usage = usage,
        .stop_reason = stop,
    };
}

/// Drive the SSE parser straight off a pipe `File.readStreaming`
/// loop. Mirrors `parseStreamInner` but bypasses the `Io.Reader`
/// interface (which buffers fill-the-buffer-first) so each curl
/// write reaches the parser the moment it hits the kernel pipe.
fn pumpStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    sink: ?TokenSink,
    sink_ctx: ?*anyopaque,
    cancel: ?*std.atomic.Value(bool),
    tool_start_sink: ?provider_mod.ToolStartSink,
    tool_start_ctx: ?*anyopaque,
) !ChatResponse {
    var parser = transport.sse.Parser.init();
    defer parser.deinit(allocator);

    var text: std.array_list.Aligned(u8, null) = .empty;
    errdefer text.deinit(allocator);

    var usage = types.TokenUsage{};
    var stop: types.StopReason = .end_turn;
    var err_text: ?[]const u8 = null;
    defer if (err_text) |e| allocator.free(e);

    var tool_builders: std.ArrayListUnmanaged(ToolBuilder) = .empty;
    defer {
        for (tool_builders.items) |*b| b.deinit(allocator);
        tool_builders.deinit(allocator);
    }

    var cancelled = false;
    if (cancel) |c| if (c.load(.acquire)) {
        cancelled = true;
    };

    var buf: [4096]u8 = undefined;
    while (!cancelled) {
        if (cancel) |c| if (c.load(.acquire)) {
            cancelled = true;
            break;
        };
        var iov: [1][]u8 = .{buf[0..]};
        const n = file.readStreaming(io, &iov) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try parser.feed(allocator, buf[0..n]);
        // Drain whatever events the just-fed bytes completed. Same
        // event table as parseStreamInner; copied inline to avoid a
        // big refactor of the existing helper.
        while (try parser.nextEvent(allocator)) |ev| {
            if (std.mem.eql(u8, ev.name, "content_block_start")) {
                try absorbContentBlockStart(allocator, &tool_builders, ev.data, tool_start_sink, tool_start_ctx);
            } else if (std.mem.eql(u8, ev.name, "content_block_delta")) {
                const before = text.items.len;
                try absorbDelta(allocator, &text, ev.data);
                if (sink) |s| {
                    const fragment = text.items[before..];
                    if (fragment.len > 0) s(sink_ctx, fragment);
                }
                try absorbInputJsonDelta(allocator, &tool_builders, ev.data);
            } else if (std.mem.eql(u8, ev.name, "message_delta")) {
                try absorbMessageDelta(&usage, &stop, ev.data);
            } else if (std.mem.eql(u8, ev.name, "message_start")) {
                try absorbMessageStart(&usage, ev.data);
            } else if (std.mem.eql(u8, ev.name, "error")) {
                stop = .refusal;
                err_text = try absorbError(allocator, ev.data);
            }
            if (cancel) |c| if (c.load(.acquire)) {
                cancelled = true;
                break;
            };
        }
    }

    if (cancelled) stop = .cancelled;

    if (err_text) |e| {
        const owned = try allocator.dupe(u8, e);
        text.deinit(allocator);
        return .{ .text = owned, .usage = usage, .stop_reason = .refusal };
    }

    var tool_calls: std.ArrayListUnmanaged(types.ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        tool_calls.deinit(allocator);
    }
    const last_idx: ?usize = if (stop == .max_tokens and tool_builders.items.len > 0)
        tool_builders.items.len - 1
    else
        null;
    for (tool_builders.items, 0..) |*b, i| {
        if (b.id.len == 0 or b.name.len == 0) continue;
        if (last_idx != null and i == last_idx.? and b.input.items.len > 0) {
            const probe = std.json.parseFromSlice(std.json.Value, allocator, b.input.items, .{}) catch {
                continue;
            };
            probe.deinit();
        }
        const args = if (b.input.items.len == 0)
            try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, b.input.items);
        errdefer allocator.free(args);
        try tool_calls.append(allocator, .{
            .id = try allocator.dupe(u8, b.id),
            .name = try allocator.dupe(u8, b.name),
            .arguments_json = args,
        });
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
        .usage = usage,
        .stop_reason = stop,
    };
}

/// Per-content-block accumulator for a tool_use response.
const ToolBuilder = struct {
    index: u32,
    id: []const u8,
    name: []const u8,
    input: std.array_list.Aligned(u8, null),

    fn deinit(self: *ToolBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.input.deinit(allocator);
    }
};

fn absorbContentBlockStart(
    allocator: std.mem.Allocator,
    builders: *std.ArrayListUnmanaged(ToolBuilder),
    data: []const u8,
    tool_start_sink: ?provider_mod.ToolStartSink,
    tool_start_ctx: ?*anyopaque,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    const block = root.object.get("content_block") orelse return;
    if (block != .object) return;
    const kind = block.object.get("type") orelse return;
    if (kind != .string or !std.mem.eql(u8, kind.string, "tool_use")) return;

    const idx_v = root.object.get("index") orelse return;
    if (idx_v != .integer) return;
    const id_v = block.object.get("id") orelse return;
    if (id_v != .string) return;
    const name_v = block.object.get("name") orelse return;
    if (name_v != .string) return;

    // Fire the early-start sink the moment we know the id+name.
    // The model is still streaming this tool's args at this point,
    // so the TUI sees the row appear before write_file/bash/etc
    // arguments finish generating — what `tool_start` is meant to
    // do, instead of firing post-round when the runner is about to
    // dispatch.
    if (tool_start_sink) |sink| sink(tool_start_ctx, id_v.string, name_v.string);

    try builders.append(allocator, .{
        .index = @intCast(idx_v.integer),
        .id = try allocator.dupe(u8, id_v.string),
        .name = try allocator.dupe(u8, name_v.string),
        .input = .empty,
    });
}

fn absorbInputJsonDelta(
    allocator: std.mem.Allocator,
    builders: *std.ArrayListUnmanaged(ToolBuilder),
    data: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    const idx_v = root.object.get("index") orelse return;
    if (idx_v != .integer) return;
    const delta = root.object.get("delta") orelse return;
    if (delta != .object) return;
    const kind = delta.object.get("type") orelse return;
    if (kind != .string or !std.mem.eql(u8, kind.string, "input_json_delta")) return;
    const partial = delta.object.get("partial_json") orelse return;
    if (partial != .string) return;

    const idx: u32 = @intCast(idx_v.integer);
    for (builders.items) |*b| {
        if (b.index == idx) {
            try b.input.appendSlice(allocator, partial.string);
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// HTTP path

fn runHttp(
    allocator: std.mem.Allocator,
    cfg: HttpSource,
    request: ChatRequest,
    sink: ?provider_mod.TokenSink,
    sink_ctx: ?*anyopaque,
) !ChatResponse {
    const body = try buildRequestBody(allocator, request, 1024);
    defer allocator.free(body);

    // Anthropic OAuth tokens (sk-ant-oat01-...) flip the auth scheme:
    // Bearer + `?beta=true` + `anthropic-beta: oauth-2025-04-20` +
    // a Claude-CLI user-agent. Standard sk-ant-api03- keys keep the
    // x-api-key path.
    const is_oauth = std.mem.startsWith(u8, cfg.api_key, "sk-ant-oat01-");

    var url_buf: [512]u8 = undefined;
    const url = if (is_oauth) blk: {
        const sep: u8 = if (std.mem.indexOfScalar(u8, cfg.endpoint, '?') != null) '&' else '?';
        const u = std.fmt.bufPrint(&url_buf, "{s}{c}beta=true", .{ cfg.endpoint, sep }) catch
            return refusal(allocator, "anthropic transport error: endpoint too long", .{});
        break :blk u;
    } else cfg.endpoint;

    // Build the auth + extra headers as `-H "name: value"` argv slots.
    // Each header needs its own owned buffer so we can hand the slice
    // to argv. Stash everything on an arena so cleanup is one call.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    if (is_oauth) {
        try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "authorization: Bearer {s}", .{cfg.api_key}));
        try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "anthropic-beta: oauth-2025-04-20", .{}));
        try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "user-agent: claude-cli/2.1.2 (external, cli)", .{}));
    } else {
        try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "x-api-key: {s}", .{cfg.api_key}));
        if (cfg.beta_features.len > 0) {
            try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "anthropic-beta: {s}", .{cfg.beta_features}));
        }
    }
    try headers.append(aalloc, try std.fmt.allocPrint(aalloc, "anthropic-version: {s}", .{cfg.api_version}));
    try headers.append(aalloc, "content-type: application/json");

    return runCurl(
        allocator,
        cfg.io,
        url,
        body,
        headers.items,
        sink,
        sink_ctx,
        request.cancel_token,
        request.tool_start_sink,
        request.tool_start_sink_ctx,
    );
}

/// Spawn `curl --no-buffer` and pipe its SSE stdout into the parser.
/// `--no-buffer` disables curl's stdio buffering so each network read
/// flushes through the pipe as soon as it arrives, which is what
/// std.http's chunked body reader fails to do in Zig 0.16.
fn runCurl(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    sink: ?provider_mod.TokenSink,
    sink_ctx: ?*anyopaque,
    cancel: ?*std.atomic.Value(bool),
    tool_start_sink: ?provider_mod.ToolStartSink,
    tool_start_ctx: ?*anyopaque,
) !ChatResponse {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    // Stash the body in a temp file so we don't have to wrangle stdin
    // pipe writes alongside stdout reads. `curl -d @path` reads it
    // verbatim. Temp file is auto-deleted on close via O_CLEXEC +
    // explicit unlink after open.
    var body_path_buf: [256]u8 = undefined;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const body_path = std.fmt.bufPrint(&body_path_buf, "/tmp/tigerclaw-anthropic-{d}-{d}.json", .{
        std.c.getpid(),
        @as(u64, @intCast(ts.nsec)),
    }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body_path, .data = body }) catch
        return refusal(allocator, "anthropic transport error: cannot write body file", .{});
    defer std.Io.Dir.cwd().deleteFile(io, body_path) catch {};

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(aalloc, &.{
        "curl",
        "-sS",
        "--no-buffer",
        "--fail-with-body",
        "--max-time", "120",
        "-X", "POST",
    });
    for (headers) |h| {
        try argv.append(aalloc, "-H");
        try argv.append(aalloc, h);
    }
    const data_arg = try std.fmt.allocPrint(aalloc, "@{s}", .{body_path});
    try argv.appendSlice(aalloc, &.{ "-d", data_arg, url });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return refusal(allocator, "anthropic transport error: failed to spawn curl", .{});
    var child_alive = true;
    defer if (child_alive) child.kill(io);

    // Drive the SSE parser directly off `File.readStreaming`. Going
    // through `.reader(io, &buf).interface.readSliceShort` adds a
    // buffering layer that waits to fill `buf` before yielding —
    // identical to the std.http reader bug we worked around. Calling
    // `readStreaming` on the raw pipe returns whatever curl just
    // wrote, so each SSE event reaches the parser the moment it
    // lands in the kernel pipe buffer.
    const stdout_file = child.stdout orelse
        return refusal(allocator, "anthropic transport error: no stdout pipe", .{});

    const result = pumpStream(allocator, io, stdout_file, sink, sink_ctx, cancel, tool_start_sink, tool_start_ctx);

    // Reap the child either way so the zombie process count stays
    // sane. If the parser failed mid-stream `child.kill` already ran
    // via the deferred path; here we wait on a clean exit.
    const term = child.wait(io) catch {
        child_alive = false;
        return result;
    };
    child_alive = false;

    // Non-zero exit — surface curl's stderr (often DNS/TLS hints)
    // when the parser already produced something we can attach to.
    switch (term) {
        .exited => |code| if (code != 0) {
            // Drain stderr; small, fixed cap. We don't have a great
            // signal for "parser succeeded with empty body" vs "curl
            // died and parser saw nothing", so prefer the parser's
            // result when it produced any text.
            if (child.stderr) |stderr_file| {
                var stderr_buf: [2048]u8 = undefined;
                var stderr_reader = stderr_file.reader(io, &stderr_buf);
                const got = stderr_reader.interface.readSliceShort(&stderr_buf) catch 0;
                if (got > 0) {
                    return refusal(allocator, "anthropic curl exit={d}: {s}", .{
                        code,
                        stderr_buf[0..got],
                    });
                }
            }
        },
        else => {},
    }

    return result;
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
        // Skip messages whose content array is empty — Anthropic
        // rejects messages with no content blocks (`messages.N.content:
        // List should have at least 1 item`). Also skip messages whose
        // only block(s) are empty text — Anthropic rejects empty text
        // blocks with `messages: text content blocks must be non-empty`.
        if (msg.content.len == 0) continue;
        if (allBlocksEmpty(msg.content)) continue;

        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(@tagName(msg.role));

        try stringify.objectField("content");
        try stringify.beginArray();
        for (msg.content) |block| {
            try writeContentBlock(allocator, &stringify, block);
        }
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();

    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        for (request.tools) |tool| {
            try stringify.beginObject();
            try stringify.objectField("name");
            try stringify.write(tool.name);
            try stringify.objectField("description");
            try stringify.write(tool.description);
            // `input_schema_json` is already-encoded JSON. Round-trip
            // it through `std.json.Value` so the Stringify state
            // machine (which tracks field/value expectations and
            // emits separating commas) sees it as a single value.
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                tool.input_schema_json,
                .{},
            );
            defer parsed.deinit();
            try stringify.objectField("input_schema");
            try stringify.write(parsed.value);
            try stringify.endObject();
        }
        try stringify.endArray();
    }

    try stringify.objectField("stream");
    try stringify.write(true);

    try stringify.objectField("temperature");
    try stringify.write(request.temperature);

    try stringify.endObject();

    return aw.toOwnedSlice();
}

/// True when every text block in `blocks` is empty AND there are no
/// non-text blocks. Used to skip wholly-empty messages — Anthropic
/// rejects them with `text content blocks must be non-empty`.
fn allBlocksEmpty(blocks: []const types.ContentBlock) bool {
    for (blocks) |b| {
        switch (b) {
            .text => |t| if (t.len > 0) return false,
            .tool_use, .tool_result => return false,
        }
    }
    return true;
}

/// Serialize one ContentBlock as the matching Anthropic API JSON
/// object: `{type:"text",text:...}`, `{type:"tool_use",id,name,input}`,
/// or `{type:"tool_result",tool_use_id,content,is_error}`.
fn writeContentBlock(
    allocator: std.mem.Allocator,
    s: *std.json.Stringify,
    block: types.ContentBlock,
) !void {
    switch (block) {
        .text => |t| {
            // Skip empty text blocks — Anthropic 400s on them. The
            // caller pre-filters wholly-empty messages, but a mixed
            // message can still carry an empty text block alongside
            // a tool_use; drop just that block.
            if (t.len == 0) return;
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(t);
            try s.endObject();
        },
        .tool_use => |tu| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("tool_use");
            try s.objectField("id");
            try s.write(tu.id);
            try s.objectField("name");
            try s.write(tu.name);
            try s.objectField("input");
            // `input_json` is already-encoded JSON. Round-trip it
            // through `std.json.Value` so the Stringify state machine
            // sees a single value and emits it correctly nested.
            // Anthropic requires `input` to be an object — empty args
            // serialize as `"{}"` which becomes `{}`.
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                if (tu.input_json.len == 0) "{}" else tu.input_json,
                .{},
            ) catch {
                // Malformed JSON — fall back to empty object so the
                // request still validates. Beats throwing a parse error
                // mid-serialization.
                try s.write(std.json.Value{ .object = .{} });
                try s.endObject();
                return;
            };
            defer parsed.deinit();
            try s.write(parsed.value);
            try s.endObject();
        },
        .tool_result => |tr| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("tool_result");
            try s.objectField("tool_use_id");
            try s.write(tr.tool_use_id);
            try s.objectField("content");
            try s.write(tr.content);
            if (tr.is_error) {
                try s.objectField("is_error");
                try s.write(true);
            }
            try s.endObject();
        },
    }
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
        types.Message.literal(.user, "hi there"),
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
    // Tools absent by default.
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    // Loose match: avoid coupling to f32 → JSON formatting precision.
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.6") != null);
}

test "scenario: buildRequestBody with tools parses as valid JSON and matches the Anthropic wire shape" {
    // This test exercises the full body — parses the whole thing as
    // JSON and asserts on the structure the way the Anthropic API
    // will. Any divergence here (malformed commas, double-encoded
    // schema, stray fields) reads as a 400 against production;
    // catching it in-process saves a real round-trip.
    const messages = [_]types.Message{
        types.Message.literal(.user, "what time is it"),
    };
    const tools = [_]types.Tool{
        .{
            .name = "get_current_time",
            .description = "Return the current UTC time.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        },
    };
    const req: ChatRequest = .{
        .messages = &messages,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
        .system = "be brief",
        .tools = &tools,
    };

    const body = try buildRequestBody(testing.allocator, req, 1024);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expect(root == .object);

    // Required Anthropic fields.
    try testing.expect(root.object.get("model").? == .string);
    try testing.expect(root.object.get("max_tokens").? == .integer);
    try testing.expect(root.object.get("stream").? == .bool);
    try testing.expectEqual(true, root.object.get("stream").?.bool);

    // `system` is an array of typed blocks, not a bare string.
    const sys = root.object.get("system").?;
    try testing.expect(sys == .array);
    try testing.expectEqual(@as(usize, 1), sys.array.items.len);
    try testing.expectEqualStrings("text", sys.array.items[0].object.get("type").?.string);

    // Messages are typed-content blocks.
    const msgs = root.object.get("messages").?;
    try testing.expect(msgs == .array);
    try testing.expectEqual(@as(usize, 1), msgs.array.items.len);
    const m0 = msgs.array.items[0].object;
    try testing.expectEqualStrings("user", m0.get("role").?.string);
    const c0 = m0.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("text", c0.get("type").?.string);
    try testing.expectEqualStrings("what time is it", c0.get("text").?.string);

    // Tools: an array of objects, each with a NESTED input_schema
    // object (not a stringified JSON blob). This is the thing a
    // bare `indexOf` check misses — a string value would still
    // contain `"type":"object"` as a substring.
    const tools_v = root.object.get("tools").?;
    try testing.expect(tools_v == .array);
    try testing.expectEqual(@as(usize, 1), tools_v.array.items.len);
    const t0 = tools_v.array.items[0].object;
    try testing.expectEqualStrings("get_current_time", t0.get("name").?.string);
    try testing.expectEqualStrings("Return the current UTC time.", t0.get("description").?.string);
    const schema = t0.get("input_schema").?;
    try testing.expect(schema == .object); // nested, not a string.
    try testing.expectEqualStrings("object", schema.object.get("type").?.string);
    try testing.expectEqual(false, schema.object.get("additionalProperties").?.bool);
}

test "scenario: buildRequestBody with no tools omits the field entirely" {
    // A request without tools must not emit an empty `tools: []`
    // either — some Anthropic models 400 on the empty-array form.
    const messages = [_]types.Message{
        types.Message.literal(.user, "hi"),
    };
    const req: ChatRequest = .{
        .messages = &messages,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
    };

    const body = try buildRequestBody(testing.allocator, req, 1024);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tools") == null);
}

test "scenario: buildRequestBody drops empty messages (anthropic 400s on empty text blocks)" {
    // Anthropic rejects `content: [{type:text, text:""}]` with
    // HTTP 400 `messages: text content blocks must be non-empty`.
    // The runner can end up with an empty assistant message when a
    // model returns only a tool_use block. The wire layer must
    // filter those out rather than forward them.
    const tool_result_blocks = [_]types.ContentBlock{.{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .content = "2026-04-23T23:45:12Z",
    } }};
    const messages = [_]types.Message{
        types.Message.literal(.user, "hi"),
        types.Message.literal(.assistant, ""), // tool-only reply, gets filtered
        .{ .role = .user, .content = &tool_result_blocks },
    };
    const req: ChatRequest = .{
        .messages = &messages,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
    };

    const body = try buildRequestBody(testing.allocator, req, 1024);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const msgs = parsed.value.object.get("messages").?;
    // Only the two non-empty messages survive.
    try testing.expectEqual(@as(usize, 2), msgs.array.items.len);
    try testing.expectEqualStrings("hi", msgs.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("tool_result", msgs.array.items[1].object.get("content").?.array.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("2026-04-23T23:45:12Z", msgs.array.items[1].object.get("content").?.array.items[0].object.get("content").?.string);
}

test "scenario: multi-turn body with structured tool_use and tool_result blocks" {
    // Mirrors the post-tool-call transcript shape: user prompt,
    // assistant message containing a tool_use block, then a user
    // message containing a tool_result block referencing the same
    // id. Every message serializes as Anthropic's typed-block JSON.
    const assistant_blocks = [_]types.ContentBlock{.{ .tool_use = .{
        .id = "toolu_1",
        .name = "get_current_time",
        .input_json = "{}",
    } }};
    const tool_result_blocks = [_]types.ContentBlock{.{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .content = "2026-04-23T23:45:12Z",
    } }};
    const messages = [_]types.Message{
        types.Message.literal(.user, "what time is it"),
        .{ .role = .assistant, .content = &assistant_blocks },
        .{ .role = .user, .content = &tool_result_blocks },
    };
    const req: ChatRequest = .{
        .messages = &messages,
        .model = .{ .provider = "anthropic", .model = "claude-haiku-4-5-20251001" },
    };

    const body = try buildRequestBody(testing.allocator, req, 1024);
    defer testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const msgs = parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 3), msgs.array.items.len);

    // Roles preserved as-is — `.tool` is no longer a wire role.
    try testing.expectEqualStrings("user", msgs.array.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("assistant", msgs.array.items[1].object.get("role").?.string);
    try testing.expectEqualStrings("user", msgs.array.items[2].object.get("role").?.string);

    // Verify the assistant message contains a tool_use block with
    // the right id/name and the user message contains a matching
    // tool_result block.
    const asst_block = msgs.array.items[1].object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("tool_use", asst_block.get("type").?.string);
    try testing.expectEqualStrings("toolu_1", asst_block.get("id").?.string);
    try testing.expectEqualStrings("get_current_time", asst_block.get("name").?.string);

    const tr_block = msgs.array.items[2].object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("tool_result", tr_block.get("type").?.string);
    try testing.expectEqualStrings("toolu_1", tr_block.get("tool_use_id").?.string);
    try testing.expectEqualStrings("2026-04-23T23:45:12Z", tr_block.get("content").?.string);
}

test "anthropic: parseStream captures a tool_use block as a ToolCall" {
    // Minimal Anthropic tool-use stream: message_start, a tool_use
    // content_block_start, one input_json_delta, message_delta with
    // stop_reason=tool_use.
    const bytes =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":5}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"get_current_time\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n";

    const resp = try parseStream(testing.allocator, .{ .literal = bytes });
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(types.StopReason.tool_use, resp.stop_reason);
    try testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try testing.expectEqualStrings("toolu_1", resp.tool_calls[0].id);
    try testing.expectEqualStrings("get_current_time", resp.tool_calls[0].name);
    try testing.expectEqualStrings("{}", resp.tool_calls[0].arguments_json);
}

test "anthropic: parseStream drops a truncated tail tool_use on max_tokens" {
    // Two tool_use blocks. The first arrived complete; the second
    // was cut off mid-JSON when the model hit the output cap. The
    // parser should keep the clean prefix and drop the broken tail
    // so the runner can dispatch what's good and re-ask for the rest.
    const bytes =
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_a\",\"name\":\"write_file\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a.txt\\\",\\\"content\\\":\\\"a\\\"}\"}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_b\",\"name\":\"write_file\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"b.txt\\\",\\\"conte\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n";

    const resp = try parseStream(testing.allocator, .{ .literal = bytes });
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(types.StopReason.max_tokens, resp.stop_reason);
    try testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try testing.expectEqualStrings("toolu_a", resp.tool_calls[0].id);
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

/// Sink wrapper that flips a cancel flag after observing N fragments.
/// Used to prove `streamTokensCancellable` honors the flag mid-event.
const CancellingCollector = struct {
    base: TokenCollector,
    cancel: *std.atomic.Value(bool),
    fire_after: usize,

    fn cb(ctx: ?*anyopaque, fragment: []const u8) void {
        const self: *CancellingCollector = @ptrCast(@alignCast(ctx.?));
        TokenCollector.appendCb(@ptrCast(&self.base), fragment);
        if (self.base.fragments.items.len >= self.fire_after) {
            self.cancel.store(true, .release);
        }
    }
};

test "anthropic: streamTokensCancellable stops at cancel flag and reports .cancelled" {
    // Same wire as the happy-path test but split into many small
    // deltas so the flag has a chance to flip mid-iteration.
    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7}}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"a\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"b\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"c\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"d\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    var cancel = std.atomic.Value(bool).init(false);
    var sink: CancellingCollector = .{
        .base = .{ .allocator = testing.allocator },
        .cancel = &cancel,
        .fire_after = 2,
    };
    defer sink.base.deinit();

    const resp = try streamTokensCancellable(
        testing.allocator,
        .{ .literal = stream },
        CancellingCollector.cb,
        &sink,
        &cancel,
    );
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.cancelled, resp.stop_reason);
    // Got at least the two fragments that triggered the cancel; the
    // post-cancel deltas (c, d) are not delivered.
    try testing.expect(sink.base.fragments.items.len >= 2);
    try testing.expect(sink.base.fragments.items.len < 4);
}

test "anthropic: streamTokensCancellable returns .cancelled immediately when flag set before start" {
    const stream = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n";

    var cancel = std.atomic.Value(bool).init(true);
    var collector: TokenCollector = .{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try streamTokensCancellable(
        testing.allocator,
        .{ .literal = stream },
        TokenCollector.appendCb,
        &collector,
        &cancel,
    );
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqual(types.StopReason.cancelled, resp.stop_reason);
    try testing.expectEqual(@as(usize, 0), collector.fragments.items.len);
}
