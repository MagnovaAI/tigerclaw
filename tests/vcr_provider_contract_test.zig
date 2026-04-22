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
            std.debug.print(
                "vcr_provider_contract: record mode not implemented for {s} — pending live HTTP wiring\n",
                .{backendName(kind)},
            );
            return error.SkipZigTest;
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

test "vcr provider contract: anthropic" {
    try runContract(.anthropic);
}

test "vcr provider contract: openai" {
    try runContract(.openai);
}
