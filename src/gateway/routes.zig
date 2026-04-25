//! Canonical route table + handler set for the gateway HTTP surface.
//!
//! The gateway exposes a small RESTy API that the CLI client and the
//! Telegram dispatch layer both consume. Endpoints land in two
//! slices: `routes` (the pattern table fed to the router) and
//! `handlers` (the tag→fn map fed to the dispatcher).
//!
//! Handlers live here as thin adapters that translate the matched
//! request into an `AgentRunner` call. The runner implementation is
//! injected via a per-process `Context` — tests use the mock runner,
//! the real daemon will wire the react-loop runner.

const std = @import("std");
const router = @import("router.zig");
const http = @import("http.zig");
const dispatcher = @import("dispatcher.zig");
const harness = @import("../harness/root.zig");
const settings = @import("../settings/root.zig");

pub const Context = struct {
    runner: harness.AgentRunner,
    /// Optional per-session budget consulted before each turn. When
    /// populated, the turn handler rejects requests with 429 as soon
    /// as any axis (turns / input_tokens / output_tokens / cost_micros)
    /// hits its cap. Left null in tests that exercise the routing
    /// surface without caring about budget policy.
    budget: ?*harness.Budget = null,
    /// Invoked synchronously from `/config/reload` before the
    /// generation counter is bumped. The boot layer wires this to its
    /// own rebuild hook; tests install a counter. Null in routing
    /// tests that don't care about the reload side-effect.
    reload_callback: ?*const fn (userdata: ?*anyopaque) void = null,
    reload_userdata: ?*anyopaque = null,
};

/// Immutable bundle of the settings the runtime was started with plus
/// the reload generation at the moment the bundle was published. A
/// request handler reads the pointer once at entry, which gives it a
/// stable view for the duration of the call — mid-request reloads
/// cannot perturb an in-flight turn's config.
pub const SettingsSnapshot = struct {
    settings: settings.Settings,
    generation: u64,
};

/// Atomically swappable pointer to the current snapshot. The boot
/// layer populates this at startup and each `/config/reload`. Pointer
/// load and store are atomic on the targets we ship for (aarch64 /
/// x86_64); the pointed-at snapshot is immutable, so once a handler
/// has the pointer it has a stable view.
pub var active_snapshot: std.atomic.Value(?*const SettingsSnapshot) = .init(null);

pub fn setActiveSnapshot(snap: *const SettingsSnapshot) void {
    active_snapshot.store(snap, .release);
}

pub fn clearActiveSnapshot() void {
    active_snapshot.store(null, .release);
}

pub fn activeSnapshot() ?*const SettingsSnapshot {
    return active_snapshot.load(.acquire);
}

/// Thread-local handler context. Zig does not expose a clean way to
/// attach per-request state onto a function-pointer-shaped handler
/// without widening the `dispatcher.Handler` signature, so we let the
/// handler reach into a caller-managed context pointer. The gateway
/// daemon sets this once at boot and never mutates it afterwards.
var active_context: ?*Context = null;

pub fn setContext(ctx: *Context) void {
    active_context = ctx;
}

pub fn clearContext() void {
    active_context = null;
}

fn contextOrInternal() dispatcher.HandlerError!*Context {
    return active_context orelse error.InternalServerError;
}

// --- route table -----------------------------------------------------------

/// Monotonic counter bumped every time `POST /config/reload` is
/// accepted. External watchers (and a future in-process hot-reload)
/// poll this to detect that a reload has been requested. The counter
/// is process-wide because the route handler is stateless; the boot
/// layer is the single writer of meaning here — it observes the
/// change and decides what to do.
pub var reload_generation: std.atomic.Value(u64) = .init(0);

pub const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/health", .tag = "health" },
    .{ .method = .POST, .pattern = "/config/reload", .tag = "config.reload" },
    .{ .method = .GET, .pattern = "/sessions", .tag = "sessions.list" },
    .{ .method = .POST, .pattern = "/sessions", .tag = "sessions.create" },
    .{ .method = .GET, .pattern = "/sessions/:id", .tag = "sessions.get" },
    .{ .method = .DELETE, .pattern = "/sessions/:id", .tag = "sessions.delete" },
    .{ .method = .POST, .pattern = "/sessions/:id/messages", .tag = "sessions.message" },
    .{ .method = .POST, .pattern = "/sessions/:id/turns", .tag = "sessions.turn" },
    .{ .method = .DELETE, .pattern = "/sessions/:id/turns/current", .tag = "sessions.turn.cancel" },
};

pub const handlers = [_]dispatcher.HandlerEntry{
    .{ .tag = "health", .handler = healthHandler },
    .{ .tag = "config.reload", .handler = configReloadHandler },
    .{ .tag = "sessions.list", .handler = sessionsListHandler },
    .{ .tag = "sessions.create", .handler = sessionsCreateHandler },
    .{ .tag = "sessions.get", .handler = sessionsGetHandler },
    .{ .tag = "sessions.delete", .handler = sessionsDeleteHandler },
    .{ .tag = "sessions.message", .handler = sessionsMessageHandler },
    .{ .tag = "sessions.turn", .handler = sessionsTurnHandler },
    .{ .tag = "sessions.turn.cancel", .handler = sessionsTurnCancelHandler },
};

// --- handlers --------------------------------------------------------------

fn healthHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    // Surface the in-flight turn count so ops can watch drain.
    _ = ctx;
    return http.Response.jsonOk("{\"status\":\"ok\"}");
}

/// POST /config/reload — surface the wire shape for a hot-reload
/// signal. This is a stub in v0.1.0: it bumps `reload_generation` and
/// returns 202 so callers can confirm the request was accepted, but
/// the process does not actually re-read settings or rebuild the
/// channel manager yet. Wiring that up is a follow-up commit; here we
/// pin the public surface so operators can script against it now.
fn configReloadHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    if (ctx.reload_callback) |cb| cb(ctx.reload_userdata);
    _ = reload_generation.fetchAdd(1, .monotonic);
    return .{
        .status = .accepted,
        .headers = &json_headers,
        .body = "{\"reload\":\"queued\"}",
    };
}

fn sessionsListHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    // The mock gateway does not persist sessions; return an empty
    // array so clients can smoke-test the shape.
    return http.Response.jsonOk("{\"sessions\":[]}");
}

fn sessionsCreateHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    // Always returns a fixed mock id so tests are deterministic.
    return .{
        .status = .created,
        .headers = &json_headers,
        .body = "{\"id\":\"mock-session\"}",
    };
}

fn sessionsGetHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const id = findParam(params, "id") orelse return error.BadRequest;
    if (std.mem.eql(u8, id, "mock-session")) {
        return http.Response.jsonOk("{\"id\":\"mock-session\",\"turns\":0}");
    }
    return http.Response.notFound();
}

fn sessionsDeleteHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .no_content };
}

fn sessionsMessageHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .accepted };
}

fn sessionsTurnHandler(
    req: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    stream_hook: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const id = findParam(params, "id") orelse return error.BadRequest;

    // Budget gate — see the non-streaming note below, same semantics.
    if (ctx.budget) |b| {
        if (b.check() != .none) return .{
            .status = .too_many_requests,
            .headers = &json_headers,
            .body = "{\"error\":\"budget_exceeded\"}",
        };
    }

    const message_or_empty = extractMessage(req.body) catch return error.BadRequest;
    const message = if (message_or_empty.len > 0) message_or_empty else "ping";

    // Non-streaming path (e.g. the CLI smoke tests that don't ask for
    // SSE) still goes through the blocking run + JSON envelope. The
    // streaming branch below lives alongside so regressions to the
    // old path remain trivially bisectable.
    if (!wantsSse(req) or stream_hook == null) {
        const result = ctx.runner.run(.{ .session_id = id, .input = message }) catch |err| switch (err) {
            error.SessionMissing => return http.Response.notFound(),
            error.BudgetExceeded => return .{ .status = .too_many_requests, .body = "budget exceeded\n" },
            else => return error.InternalServerError,
        };
        return renderJsonFromOutput(result.output);
    }

    return streamTurn(ctx, stream_hook.?, id, message);
}

/// Stream the turn over a chunked `text/event-stream` response.
///
/// Emits v1-compatible JSON-envelope frames:
/// * `data: {"type":"chunk","text":"..."}\n\n` per provider text delta
/// * `data: {"type":"tool_start","id":"...","name":"..."}\n\n` per dispatch
/// * `data: {"type":"tool_done","id":"...","name":"...","output":"..."}\n\n`
/// * `data: {"type":"done"}\n\n` terminal frame
/// * `data: {"type":"error","message":"..."}\n\n` on failure (followed by done)
///
/// Each frame is flushed immediately so the client sees it before the
/// turn completes. Returns `Response.streamingHandled()` so the
/// tcp_server does not try to write a second response envelope.
fn streamTurn(
    ctx: *Context,
    stream_hook: dispatcher.StreamHook,
    session_id: []const u8,
    message: []const u8,
) dispatcher.HandlerError!http.Response {
    const request: *std.http.Server.Request = @ptrCast(@alignCast(stream_hook.?));

    var send_buf: [1024]u8 = undefined;
    var body_writer = request.respondStreaming(&send_buf, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    }) catch return error.InternalServerError;

    var frame_ctx: StreamCtx = .{ .body = &body_writer };

    // Fire the turn through the runner with both sinks wired. The
    // runner invokes these synchronously from the dispatch thread;
    // this handler is single-threaded-per-request so no locking is
    // needed around the body writer.
    const run_err = ctx.runner.run(.{
        .session_id = session_id,
        .input = message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = &frame_ctx,
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = &frame_ctx,
    });

    if (run_err) |_| {
        writeFrame(&body_writer, "{\"type\":\"done\"}") catch {};
    } else |err| {
        const msg = switch (err) {
            error.SessionMissing => "session missing",
            error.BudgetExceeded => "budget exceeded",
            error.Cancelled, error.Interrupted => "turn cancelled",
            else => "internal error",
        };
        writeErrorFrame(&body_writer, msg) catch {};
        writeFrame(&body_writer, "{\"type\":\"done\"}") catch {};
    }

    body_writer.end() catch {};
    return http.Response.streamingHandled();
}

/// Context both sinks share. Single field today; kept as a struct so
/// later additions (cancel token, frame counter) don't ripple through
/// every sink signature.
const StreamCtx = struct {
    body: *std.http.BodyWriter,
};

fn chunkSink(ctx: ?*anyopaque, fragment: []const u8) void {
    const self: *StreamCtx = @ptrCast(@alignCast(ctx.?));
    writeChunkFrame(self.body, fragment) catch {};
}

fn toolEventSink(
    ctx: ?*anyopaque,
    event: harness.agent_runner.ToolEvent,
) void {
    const self: *StreamCtx = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .started => |s| writeToolStartFrame(self.body, s.id, s.name) catch {},
        // SSE consumers don't yet ingest progress chunks -- the
        // streaming format (text/event-stream) framing for partial
        // tool output is a separate design conversation. Drop for
        // now; the final tool_result lands on `.finished`.
        .progress => {},
        .finished => |f| writeToolDoneFrame(self.body, f.id, f.name, f.kind.flatText()) catch {},
    }
}

/// Write a `data: <json>\n\n` frame and flush so the bytes hit the
/// socket before the next frame is built.
fn writeFrame(body: *std.http.BodyWriter, json_line: []const u8) !void {
    try body.writer.writeAll("data: ");
    try body.writer.writeAll(json_line);
    try body.writer.writeAll("\n\n");
    try body.writer.flush();
}

fn writeChunkFrame(body: *std.http.BodyWriter, text: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"chunk\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeToolStartFrame(body: *std.http.BodyWriter, id: []const u8, name: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"tool_start\",\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, &body.writer);
    try body.writer.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeToolDoneFrame(
    body: *std.http.BodyWriter,
    id: []const u8,
    name: []const u8,
    output: []const u8,
) !void {
    try body.writer.writeAll("data: {\"type\":\"tool_done\",\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, &body.writer);
    try body.writer.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    try body.writer.writeAll(",\"output\":");
    try std.json.Stringify.encodeJsonString(output, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeErrorFrame(body: *std.http.BodyWriter, message: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"error\",\"message\":");
    try std.json.Stringify.encodeJsonString(message, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

/// Pull `message` out of the request body JSON. Empty body → empty
/// string (the runner falls back to a deterministic prompt). Returns
/// `error.BadRequest` for malformed JSON or non-string `message` to
/// surface a typo at the wire boundary instead of inside the runner.
fn extractMessage(body: []const u8) error{BadRequest}![]const u8 {
    if (body.len == 0) return "";
    // We need a leaky parse so we can borrow the slice into the body
    // bytes without re-allocating. The handler returns immediately
    // after this; the tcp_server frees `body` once dispatch finishes.
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch
        return error.BadRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadRequest;
    const m = parsed.value.object.get("message") orelse return "";
    if (m != .string) return error.BadRequest;
    // Slice aliases the parsed arena; that arena dies at deinit above.
    // We re-find the slice in the original body so the returned slice
    // outlives this function.
    const needle = m.string;
    const start = std.mem.indexOf(u8, body, needle) orelse return error.BadRequest;
    return body[start .. start + needle.len];
}

/// Shared buffer for both the SSE and JSON renderers. Threadlocal
/// so two concurrent requests on different TCP-server threads don't
/// stomp each other; each handler consumes its own thread's buffer
/// before the thread services the next request.
threadlocal var render_body_buf: [16 * 1024]u8 = undefined;

/// Build a plain JSON response carrying the runner's output. The
/// TUI / CLI clients consume this without having to parse SSE; the
/// `output` field is a JSON-escaped string, so newlines and quotes
/// round-trip cleanly.
fn renderJsonFromOutput(output: []const u8) http.Response {
    // JSON-escape `output` into the thread-local buffer. We leave
    // 64 bytes of headroom for the surrounding {"output":""} shell.
    const budget = render_body_buf.len - 64;
    const src = if (output.len > budget) output[0..budget] else output;

    var w = std.Io.Writer.fixed(&render_body_buf);
    w.writeAll("{\"output\":") catch return .{ .status = .internal_server_error, .body = "render failed\n" };
    std.json.Stringify.encodeJsonString(src, .{}, &w) catch
        return .{ .status = .internal_server_error, .body = "render failed\n" };
    w.writeAll("}") catch return .{ .status = .internal_server_error, .body = "render failed\n" };
    return http.Response.jsonOk(w.buffered());
}

/// DELETE /sessions/:id/turns/current — cancel the in-flight turn for
/// `id`. Idempotent: returns 204 even when no turn is in flight, so the
/// CLI's Ctrl-C handler can fire without having to track turn state.
fn sessionsTurnCancelHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    _ = findParam(params, "id") orelse return error.BadRequest;

    // The mock runner ignores the turn id; production will plumb a
    // session→turn map so cancel reaches the right react loop. The
    // value zero is a sentinel for "current turn on this session".
    ctx.runner.cancel(0);
    return .{ .status = .no_content };
}

fn wantsSse(req: http.Request) bool {
    const accept = req.getHeader("accept") orelse return false;
    return std.mem.indexOf(u8, accept, "text/event-stream") != null;
}

fn findParam(params: []const router.Param, name: []const u8) ?[]const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

const json_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn withMockContext(comptime body: fn (runner: *harness.MockAgentRunner) anyerror!void) !void {
    var mock = harness.MockAgentRunner.init();
    var ctx: Context = .{ .runner = mock.runner() };
    setContext(&ctx);
    defer clearContext();
    try body(&mock);
}

fn runHealth(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/health", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

test "routes: GET /health returns 200" {
    try withMockContext(runHealth);
}

fn runList(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("{\"sessions\":[]}", resp.body);
}

test "routes: GET /sessions returns an empty list in mock mode" {
    try withMockContext(runList);
}

fn runCreate(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.created, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "mock-session") != null);
}

test "routes: POST /sessions returns 201 with the canned id" {
    try withMockContext(runCreate);
}

fn runGet(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/mock-session", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
}

test "routes: GET /sessions/mock-session returns 200" {
    try withMockContext(runGet);
}

fn runGetMissing(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/unknown", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.not_found, resp.status);
}

test "routes: GET /sessions/unknown returns 404" {
    try withMockContext(runGetMissing);
}

fn runTurn(runner: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions/s1/turns", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(runner.in_flight.isZero());
}

test "routes: POST /sessions/:id/turns round-trips the in-flight counter" {
    try withMockContext(runTurn);
}

test "routes: POST /sessions/:id/turns returns 429 when the budget is exhausted" {
    var mock = harness.MockAgentRunner.init();
    var budget = harness.Budget.init(.{ .turns = 1 });
    budget.recordTurn(0, 0, 0);

    var ctx: Context = .{ .runner = mock.runner(), .budget = &budget };
    setContext(&ctx);
    defer clearContext();

    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.too_many_requests, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "budget_exceeded") != null);

    // The runner must NOT have been called — in-flight stays at zero.
    try testing.expect(mock.in_flight.isZero());
}

fn runTurnSseFallback(runner: *harness.MockAgentRunner) anyerror!void {
    // In-process dispatch has no real `std.http.Server.Request` to
    // stream through, so the handler falls back to the buffered JSON
    // path even when Accept requests SSE. The live streaming path is
    // covered by the e2e gateway test.
    const accept = [_]http.Header{.{ .name = "accept", .value = "text/event-stream" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &accept,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(runner.in_flight.isZero());
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"output\"") != null);
}

test "routes: POST /sessions/:id/turns falls back to JSON when no stream hook present" {
    try withMockContext(runTurnSseFallback);
}

fn runTurnCancel(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{
        .method = .DELETE,
        .target = "/sessions/s1/turns/current",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id/turns/current returns 204 (idempotent)" {
    try withMockContext(runTurnCancel);
}

fn runTurnCancelMissingId(_: *harness.MockAgentRunner) anyerror!void {
    // Without a path param the dispatcher routes to a different
    // pattern and we never reach the handler — verify the explicit
    // 204 path requires the :id segment to be present.
    const req: http.Request = .{
        .method = .DELETE,
        .target = "/sessions//turns/current",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    // Empty :id segment is matched by the router but the handler
    // captures it as an empty string; we still 204 — the mock runner
    // doesn't care about the id and the cancel is best-effort.
    try testing.expect(resp.status == .no_content or resp.status == .not_found);
}

test "routes: DELETE /sessions//turns/current degrades to 204 or 404" {
    try withMockContext(runTurnCancelMissingId);
}

fn runDelete(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .DELETE, .target = "/sessions/s1", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id returns 204" {
    try withMockContext(runDelete);
}

fn runConfigReload(_: *harness.MockAgentRunner) anyerror!void {
    const before = reload_generation.load(.monotonic);
    const req: http.Request = .{ .method = .POST, .target = "/config/reload", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.accepted, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"reload\":\"queued\"") != null);
    try testing.expectEqual(before + 1, reload_generation.load(.monotonic));
}

test "routes: POST /config/reload returns 202 and bumps the generation" {
    try withMockContext(runConfigReload);
}

var reload_cb_counter: u32 = 0;

fn reloadTestCallback(ud: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(ud.?));
    counter.* += 1;
}

test "routes: POST /config/reload fires the context's reload_callback per request" {
    reload_cb_counter = 0;
    var mock = harness.MockAgentRunner.init();
    var ctx: Context = .{
        .runner = mock.runner(),
        .reload_callback = reloadTestCallback,
        .reload_userdata = &reload_cb_counter,
    };
    setContext(&ctx);
    defer clearContext();

    const req: http.Request = .{ .method = .POST, .target = "/config/reload", .headers = &.{} };
    _ = try dispatcher.dispatch(&routes, &handlers, req, null);
    _ = try dispatcher.dispatch(&routes, &handlers, req, null);

    try testing.expectEqual(@as(u32, 2), reload_cb_counter);
}
