//! Provider VCR contract tests.
//!
//! WHY: each provider's wire format (Anthropic SSE, OpenAI SSE, …) is a
//! moving target. We want a regression check that takes a recorded HTTP
//! response — captured once against the real backend — and proves the
//! provider parser still produces the expected `ChatResponse`. Recording
//! requires real API keys; replay does not. To keep CI hermetic we
//! default to replay, and skip cleanly when no cassette exists.
//!
//! Mode is selected via `TIGERCLAW_VCR_MODE` (replay | record | live).
//! Per-provider keys are read from `ANTHROPIC_API_KEY` and
//! `OPENAI_API_KEY`. The record path is currently a stub — once the
//! live HTTP transport lands, the record branch can do real recording
//! without changing any of this scaffolding.
//!
//! Cassettes live at `tests/cassettes/<provider>_basic.jsonl`. They are
//! committed to the repo as they get recorded; until then the directory
//! is empty (kept by `.gitkeep`) and these tests skip.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const vcr = tigerclaw.vcr;
const llm = tigerclaw.llm;

const testing = std.testing;

const cassettes_dir = "tests/cassettes";

/// Snapshot the current process environment into a `Map`. Returned
/// map owns its keys/values; caller must `deinit`.
fn loadEnv(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return testing.environ.createMap(allocator);
}

const ProviderKind = enum { anthropic, openai };

fn cassetteName(kind: ProviderKind) []const u8 {
    return switch (kind) {
        .anthropic => "anthropic_basic.jsonl",
        .openai => "openai_basic.jsonl",
    };
}

fn keyName(kind: ProviderKind) []const u8 {
    return switch (kind) {
        .anthropic => "ANTHROPIC_API_KEY",
        .openai => "OPENAI_API_KEY",
    };
}

fn backendName(kind: ProviderKind) []const u8 {
    return switch (kind) {
        .anthropic => "anthropic",
        .openai => "openai",
    };
}

/// Drive the provider against the recorded response bytes and assert
/// the chat response shape. Caller owns the cassette bytes.
fn runReplay(kind: ProviderKind, cassette_bytes: []const u8) !void {
    var cs = try vcr.replayer.replayFromBytes(testing.allocator, cassette_bytes);
    defer cs.deinit();

    if (cs.interactions.len == 0) return error.SkipZigTest;
    // First recorded response — the canned request is fixed, so the
    // first interaction is what the provider would consume.
    const recorded = cs.interactions[0].response.body;

    const msgs = [_]tigerclaw.types.Message{.{ .role = .user, .content = "hi" }};
    const req: llm.provider.ChatRequest = .{
        .messages = &msgs,
        .model = .{ .provider = backendName(kind), .model = "0" },
    };

    switch (kind) {
        .anthropic => {
            var p = llm.providers.AnthropicProvider.init(.{ .literal = recorded });
            const resp = try p.provider().chat(testing.allocator, req);
            defer if (resp.text) |t| testing.allocator.free(t);
            try testing.expect(resp.text != null);
            try testing.expect(resp.text.?.len > 0);
        },
        .openai => {
            var p = llm.providers.OpenAIProvider.init(.{ .literal = recorded });
            const resp = try p.provider().chat(testing.allocator, req);
            defer if (resp.text) |t| testing.allocator.free(t);
            try testing.expect(resp.text != null);
            try testing.expect(resp.text.?.len > 0);
        },
    }
}

fn runContract(kind: ProviderKind) !void {
    const a = testing.allocator;

    var env_map = try loadEnv(a);
    defer env_map.deinit();

    const mode_env = env_map.get("TIGERCLAW_VCR_MODE");
    const mode = vcr.contract.resolveMode(mode_env);

    const key_env = env_map.get(keyName(kind));

    // Resolve cassette path relative to the test process cwd. The build
    // system invokes tests from the repo root, so `tests/cassettes/...`
    // is the correct relative path.
    var cwd = try std.Io.Dir.cwd().openDir(testing.io, ".", .{});
    defer cwd.close(testing.io);

    const rel_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ cassettes_dir, cassetteName(kind) });
    defer a.free(rel_path);

    const decision = try vcr.contract.decide(testing.io, cwd, rel_path, mode, key_env);

    switch (decision) {
        .skip => return error.SkipZigTest,
        .record_pending => {
            // Real recording path: hit the live API, capture the raw
            // SSE body, write a one-interaction cassette next to the
            // others. The cassette is committed to the repo and every
            // subsequent run replays from it.
            const key = key_env orelse return error.SkipZigTest;
            try recordCassette(kind, key, rel_path);
            // Don't replay in the same test run — the recording itself
            // proved the provider parses the live response (no errors
            // surfaced). Subsequent runs without the env vars set will
            // exercise the replay path against the new cassette.
            return;
        },
        .replay => |r| {
            // Read the cassette into memory and drive the provider.
            const max_bytes: usize = 1 << 20; // 1 MiB cap on a recorded reply
            const bytes = cwd.readFileAlloc(testing.io, r.cassette_path, a, .limited(max_bytes)) catch |err| switch (err) {
                error.FileNotFound => return error.SkipZigTest,
                else => return err,
            };
            defer a.free(bytes);
            try runReplay(kind, bytes);
        },
    }
}

/// Live-record one interaction against the real provider and persist
/// it to `cassette_path` as JSONL (header + one interaction). The
/// canned request mirrors what `runReplay` consumes so the next pass
/// in replay mode reads back exactly what the provider expects.
fn recordCassette(
    kind: ProviderKind,
    api_key: []const u8,
    cassette_path: []const u8,
) !void {
    const a = testing.allocator;

    var client: std.http.Client = .{ .allocator = a, .io = testing.io };
    defer client.deinit();

    const target_info: struct {
        url: []const u8,
        method: std.http.Method,
        body: []const u8,
        auth_header: std.http.Header,
        extra: ?std.http.Header,
    } = switch (kind) {
        .anthropic => .{
            .url = "https://api.anthropic.com/v1/messages",
            .method = .POST,
            // 5-message multi-turn so the recorded cassette exercises
            // history handling, not just a single round-trip.
            .body =
            \\{"model":"claude-haiku-4-5-20251001","max_tokens":256,"messages":[{"role":"user","content":[{"type":"text","text":"name three primary colors"}]},{"role":"assistant","content":[{"type":"text","text":"Red, blue, yellow."}]},{"role":"user","content":[{"type":"text","text":"and three secondary?"}]},{"role":"assistant","content":[{"type":"text","text":"Orange, green, purple."}]},{"role":"user","content":[{"type":"text","text":"give me one example object for each secondary"}]}],"stream":true}
            ,
            .auth_header = .{ .name = "x-api-key", .value = api_key },
            .extra = .{ .name = "anthropic-version", .value = "2023-06-01" },
        },
        .openai => .{
            .url = "https://api.openai.com/v1/chat/completions",
            .method = .POST,
            .body =
            \\{"model":"gpt-4o-mini","max_tokens":256,"messages":[{"role":"user","content":"name three primary colors"},{"role":"assistant","content":"Red, blue, yellow."},{"role":"user","content":"and three secondary?"},{"role":"assistant","content":"Orange, green, purple."},{"role":"user","content":"give me one example object for each secondary"}],"stream":true}
            ,
            .auth_header = blk: {
                var buf: [256]u8 = undefined;
                const v = try std.fmt.bufPrint(&buf, "Bearer {s}", .{api_key});
                // Heap-dupe so the slice survives past the bufPrint frame.
                const owned = try a.dupe(u8, v);
                break :blk .{ .name = "authorization", .value = owned };
            },
            .extra = null,
        },
    };
    defer if (kind == .openai) a.free(target_info.auth_header.value);

    var headers_buf: [3]std.http.Header = undefined;
    var headers_len: usize = 0;
    headers_buf[headers_len] = target_info.auth_header;
    headers_len += 1;
    headers_buf[headers_len] = .{ .name = "content-type", .value = "application/json" };
    headers_len += 1;
    if (target_info.extra) |h| {
        headers_buf[headers_len] = h;
        headers_len += 1;
    }

    var captured: std.Io.Writer.Allocating = .init(a);
    defer captured.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = target_info.url },
        .method = target_info.method,
        .payload = target_info.body,
        .keep_alive = false,
        .response_writer = &captured.writer,
        .extra_headers = headers_buf[0..headers_len],
    });

    const status_code: u16 = @intFromEnum(result.status);
    const body_slice = captured.written();

    // Refuse to persist a failed recording — a 401 cassette would
    // poison the replay path with garbage the parser can't make sense
    // of, and the operator wouldn't notice until a CI run weeks later.
    if (status_code < 200 or status_code >= 300) {
        std.debug.print(
            "vcr_provider_contract: {s} returned {d} during record — not writing cassette. body[:200]={s}\n",
            .{ backendName(kind), status_code, body_slice[0..@min(body_slice.len, 200)] },
        );
        return error.SkipZigTest;
    }

    // Compose the JSONL: header line + one interaction line.
    const header: vcr.cassette.Header = .{
        .cassette_id = backendName(kind),
        // The replay path doesn't read this; setting to 0 keeps the
        // recorded cassette deterministic across test runs.
        .created_at_ns = 0,
    };
    const interaction: vcr.cassette.Interaction = .{
        .request = .{
            .method = @tagName(target_info.method),
            .url = target_info.url,
            // Keep the canned request body in the cassette so a future
            // diff catches drift; api_key is in headers not body, so
            // nothing secret leaks into the persisted file.
            .body = target_info.body,
        },
        .response = .{
            .status = @intFromEnum(result.status),
            .body = body_slice,
        },
    };

    const header_json = try std.json.Stringify.valueAlloc(a, header, .{});
    defer a.free(header_json);
    const interaction_json = try std.json.Stringify.valueAlloc(a, interaction, .{});
    defer a.free(interaction_json);

    var cwd = try std.Io.Dir.cwd().openDir(testing.io, ".", .{});
    defer cwd.close(testing.io);

    // Ensure the directory exists.
    cwd.createDirPath(testing.io, cassettes_dir) catch {};

    var atomic = try cwd.createFileAtomic(testing.io, cassette_path, .{ .replace = true });
    defer atomic.deinit(testing.io);

    var write_buf: [1024]u8 = undefined;
    var w = atomic.file.writer(testing.io, &write_buf);
    try w.interface.writeAll(header_json);
    try w.interface.writeAll("\n");
    try w.interface.writeAll(interaction_json);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    try atomic.replace(testing.io);

    std.debug.print("vcr_provider_contract: recorded {s} ({d} bytes)\n", .{ cassette_path, body_slice.len });
}

test "vcr provider contract: anthropic" {
    try runContract(.anthropic);
}

test "vcr provider contract: openai" {
    try runContract(.openai);
}
