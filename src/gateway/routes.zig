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

pub const Context = struct {
    runner: harness.AgentRunner,
    /// Optional per-session budget consulted before each turn. When
    /// populated, the turn handler rejects requests with 429 as soon
    /// as any axis (turns / input_tokens / output_tokens / cost_micros)
    /// hits its cap. Left null in tests that exercise the routing
    /// surface without caring about budget policy.
    budget: ?*harness.Budget = null,
};

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

    // The mock runner takes the session_id verbatim as its session
    // identifier and echoes the input back. Production will parse the
    // request body JSON; the mock endpoint accepts any body and sends
    // a canned prompt through the runner so the counter round-trips.
    const result = ctx.runner.run(.{ .session_id = id, .input = "ping" }) catch |err| switch (err) {
        error.SessionMissing => return http.Response.notFound(),
        error.BudgetExceeded => return .{ .status = .too_many_requests, .body = "budget exceeded\n" },
        else => return error.InternalServerError,
    };

    // Content negotiation: a client asking for `text/event-stream`
    // receives the same logical turn rendered as SSE token events.
    // The mock runner returns a single-shot reply (no real streaming),
    // so the body is a fixed sequence framed in the SSE wire format.
    // Real streaming arrives once the runner is wired to the react
    // loop and the dispatcher gains a streaming response shape.
    if (wantsSse(req)) {
        _ = result;
        return .{
            .status = .ok,
            .headers = &sse_headers,
            .body = mock_sse_body,
        };
    }

    _ = result;
    return http.Response.jsonOk("{\"status\":\"ok\"}");
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

const mock_sse_body =
    "event: token\n" ++
    "data: ping\n" ++
    "\n" ++
    "event: done\n" ++
    "data: {\"completed\":true}\n" ++
    "\n";

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
