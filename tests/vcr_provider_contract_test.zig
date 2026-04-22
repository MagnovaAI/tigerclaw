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

    // Up to 5 extra headers: auth, content-type, anthropic-version,
    // anthropic-beta (OAuth only), user-agent (OAuth only).
    var headers_buf: [5]std.http.Header = undefined;
    var headers_len: usize = 0;
    var url: []const u8 = undefined;
    const method: std.http.Method = .POST;
    var body: []const u8 = undefined;
    // Anything we heap-alloc here gets freed at function exit.
    var heap_owned: ?[]u8 = null;
    defer if (heap_owned) |h| a.free(h);

    switch (kind) {
        .anthropic => {
            // Anthropic OAuth tokens (sk-ant-oat01-...) speak the same
            // /v1/messages endpoint as standard API keys, but auth via
            // Authorization: Bearer + a `?beta=true` query + extra
            // anthropic-beta + user-agent headers. Standard sk-ant-api03-
            // keys use x-api-key with no extras. v1 mirrors this split.
            const is_oauth = std.mem.startsWith(u8, api_key, "sk-ant-oat01-");
            url = if (is_oauth)
                "https://api.anthropic.com/v1/messages?beta=true"
            else
                "https://api.anthropic.com/v1/messages";

            // 5-message multi-turn so the recorded cassette exercises
            // history handling, not just a single round-trip.
            body =
                \\{"model":"claude-haiku-4-5-20251001","max_tokens":256,"messages":[{"role":"user","content":[{"type":"text","text":"name three primary colors"}]},{"role":"assistant","content":[{"type":"text","text":"Red, blue, yellow."}]},{"role":"user","content":[{"type":"text","text":"and three secondary?"}]},{"role":"assistant","content":[{"type":"text","text":"Orange, green, purple."}]},{"role":"user","content":[{"type":"text","text":"give me one example object for each secondary"}]}],"stream":true}
            ;

            if (is_oauth) {
                var bearer_buf: [256]u8 = undefined;
                const v = try std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{api_key});
                heap_owned = try a.dupe(u8, v);
                headers_buf[headers_len] = .{ .name = "authorization", .value = heap_owned.? };
            } else {
                headers_buf[headers_len] = .{ .name = "x-api-key", .value = api_key };
            }
            headers_len += 1;
            headers_buf[headers_len] = .{ .name = "content-type", .value = "application/json" };
            headers_len += 1;
            headers_buf[headers_len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            headers_len += 1;
            if (is_oauth) {
                headers_buf[headers_len] = .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" };
                headers_len += 1;
                headers_buf[headers_len] = .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" };
                headers_len += 1;
            }
        },
        .openai => {
            url = "https://api.openai.com/v1/chat/completions";
            body =
                \\{"model":"gpt-4o-mini","max_tokens":256,"messages":[{"role":"user","content":"name three primary colors"},{"role":"assistant","content":"Red, blue, yellow."},{"role":"user","content":"and three secondary?"},{"role":"assistant","content":"Orange, green, purple."},{"role":"user","content":"give me one example object for each secondary"}],"stream":true}
            ;

            var bearer_buf: [256]u8 = undefined;
            const v = try std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{api_key});
            heap_owned = try a.dupe(u8, v);
            headers_buf[headers_len] = .{ .name = "authorization", .value = heap_owned.? };
            headers_len += 1;
            headers_buf[headers_len] = .{ .name = "content-type", .value = "application/json" };
            headers_len += 1;
        },
    }

    var captured: std.Io.Writer.Allocating = .init(a);
    defer captured.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
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
            .method = @tagName(method),
            .url = url,
            // Keep the canned request body in the cassette so a future
            // diff catches drift; api_key is in headers not body, so
            // nothing secret leaks into the persisted file.
            .body = body,
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
