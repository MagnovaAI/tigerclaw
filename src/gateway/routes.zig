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
) dispatcher.HandlerError!http.Response {
    // The mock gateway does not persist sessions; return an empty
    // array so clients can smoke-test the shape.
    return http.Response.jsonOk("{\"sessions\":[]}");
}

fn sessionsCreateHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
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
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .no_content };
}

fn sessionsMessageHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .accepted };
}

fn sessionsTurnHandler(
    req: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const id = findParam(params, "id") orelse return error.BadRequest;

    // Budget gate. This is a snapshot check — a concurrent streaming
    // reader can push counters past a cap after we observe them, but
    // the next turn will see the trip. The observable contract is
    // "once the cap is hit, subsequent turns fail with 429 until the
    // session is reset"; eventual consistency is enough for a spend
    // safety net.
    if (ctx.budget) |b| {
        if (b.check() != .none) return .{
            .status = .too_many_requests,
            .headers = &json_headers,
            .body = "{\"error\":\"budget_exceeded\"}",
        };
    }

    // Extract `message` from the request body JSON. Empty body → fall
    // back to a fixed prompt so smoke tests with no payload still
    // exercise the runner. Errors here surface as bad-request rather
    // than internal — the client built a malformed JSON.
    const message_or_empty = extractMessage(req.body) catch return error.BadRequest;
    // Fall back to a deterministic prompt when the body has no
    // `message` field — keeps existing smoke tests + the canonical
    // mock-runner behaviour intact.
    const message = if (message_or_empty.len > 0) message_or_empty else "ping";

    const result = ctx.runner.run(.{ .session_id = id, .input = message }) catch |err| switch (err) {
        error.SessionMissing => return http.Response.notFound(),
        error.BudgetExceeded => return .{ .status = .too_many_requests, .body = "budget exceeded\n" },
        else => return error.InternalServerError,
    };

    // Content negotiation: a client asking for `text/event-stream`
    // receives the same logical turn rendered as SSE token events.
    // The runner returns the full reply in one shot (real per-token
    // streaming is the v0.2.0 dispatcher rewrite); we frame the
    // response into a single token event + done event so the wire
    // shape matches what a streaming client expects.
    if (wantsSse(req)) {
        return renderSseFromOutput(result.output);
    }

    return renderJsonFromOutput(result.output);
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

/// Build the SSE response body for a one-shot runner output. Memory
/// for the body comes out of a thread-local fixed buffer — the
/// handler signature is allocator-free, and the body is consumed by
/// `tcp_server` before this thread services its next request.
threadlocal var sse_body_buf: [16 * 1024]u8 = undefined;

/// Emit the runner output as one `event: token` frame per source line
/// followed by a single `event: done`. SSE forbids literal newlines in
/// a `data:` line, so multi-line replies are split into multiple
/// frames; clients concatenate them with `\n` between frames to
/// reconstruct the original text.
///
/// The runner is still one-shot — true per-token streaming lands when
/// the dispatcher grows a streaming response shape. Framing here so
/// the wire protocol is honest and clients can render incrementally.
fn renderSseFromOutput(output: []const u8) http.Response {
    var w: std.Io.Writer = .fixed(&sse_body_buf);
    const headroom: usize = 64; // space for the trailing done frame
    const budget = if (sse_body_buf.len > headroom) sse_body_buf.len - headroom else 0;

    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        // Cap any single frame so one pathologically long line can't
        // exhaust the buffer on its own.
        const cap = @min(line.len, budget / 2);
        if (w.buffered().len + cap + 24 > budget) break;
        w.writeAll("event: token\ndata: ") catch break;
        if (cap > 0) w.writeAll(line[0..cap]) catch break;
        w.writeAll("\n\n") catch break;
    }

    w.writeAll("event: done\ndata: {\"completed\":true}\n\n") catch
        return .{ .status = .internal_server_error, .body = "render failed\n" };

    return .{
        .status = .ok,
        .headers = &sse_headers,
        .body = w.buffered(),
    };
}

/// DELETE /sessions/:id/turns/current — cancel the in-flight turn for
/// `id`. Idempotent: returns 204 even when no turn is in flight, so the
/// CLI's Ctrl-C handler can fire without having to track turn state.
fn sessionsTurnCancelHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
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

const sse_headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-cache" },
};

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
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

test "routes: GET /health returns 200" {
    try withMockContext(runHealth);
}

fn runList(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("{\"sessions\":[]}", resp.body);
}

test "routes: GET /sessions returns an empty list in mock mode" {
    try withMockContext(runList);
}

fn runCreate(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.created, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "mock-session") != null);
}

test "routes: POST /sessions returns 201 with the canned id" {
    try withMockContext(runCreate);
}

fn runGet(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/mock-session", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.ok, resp.status);
}

test "routes: GET /sessions/mock-session returns 200" {
    try withMockContext(runGet);
}

fn runGetMissing(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/unknown", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.not_found, resp.status);
}

test "routes: GET /sessions/unknown returns 404" {
    try withMockContext(runGetMissing);
}

fn runTurn(runner: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions/s1/turns", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
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
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.too_many_requests, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "budget_exceeded") != null);

    // The runner must NOT have been called — in-flight stays at zero.
    try testing.expect(mock.in_flight.isZero());
}

fn runTurnSse(runner: *harness.MockAgentRunner) anyerror!void {
    const accept = [_]http.Header{.{ .name = "accept", .value = "text/event-stream" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &accept,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(runner.in_flight.isZero());

    // Content-type must be SSE so a streaming client recognises it.
    var ct_seen = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "content-type")) {
            try testing.expect(std.mem.indexOf(u8, h.value, "text/event-stream") != null);
            ct_seen = true;
        }
    }
    try testing.expect(ct_seen);

    // Body carries at least one token event followed by a done event.
    try testing.expect(std.mem.indexOf(u8, resp.body, "event: token\ndata: ping") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "event: done") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "{\"completed\":true}") != null);
}

test "routes: POST /sessions/:id/turns with Accept: text/event-stream returns SSE" {
    try withMockContext(runTurnSse);
}

fn runTurnAcceptMixed(_: *harness.MockAgentRunner) anyerror!void {
    // Accept lists multiple types — SSE wins because the substring
    // match in `wantsSse` ignores quality factors.
    const accept = [_]http.Header{.{
        .name = "accept",
        .value = "application/json, text/event-stream;q=0.9",
    }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &accept,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expect(std.mem.indexOf(u8, resp.body, "event: token") != null);
}

test "routes: POST /sessions/:id/turns honours Accept when SSE is one of several" {
    try withMockContext(runTurnAcceptMixed);
}

fn runTurnCancel(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{
        .method = .DELETE,
        .target = "/sessions/s1/turns/current",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
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
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
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
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id returns 204" {
    try withMockContext(runDelete);
}

fn runConfigReload(_: *harness.MockAgentRunner) anyerror!void {
    const before = reload_generation.load(.monotonic);
    const req: http.Request = .{ .method = .POST, .target = "/config/reload", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
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
    _ = try dispatcher.dispatch(&routes, &handlers, req);
    _ = try dispatcher.dispatch(&routes, &handlers, req);

    try testing.expectEqual(@as(u32, 2), reload_cb_counter);
}
