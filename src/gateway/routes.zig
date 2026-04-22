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

pub const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/health", .tag = "health" },
    .{ .method = .GET, .pattern = "/sessions", .tag = "sessions.list" },
    .{ .method = .POST, .pattern = "/sessions", .tag = "sessions.create" },
    .{ .method = .GET, .pattern = "/sessions/:id", .tag = "sessions.get" },
    .{ .method = .DELETE, .pattern = "/sessions/:id", .tag = "sessions.delete" },
    .{ .method = .POST, .pattern = "/sessions/:id/messages", .tag = "sessions.message" },
    .{ .method = .POST, .pattern = "/sessions/:id/turns", .tag = "sessions.turn" },
};

pub const handlers = [_]dispatcher.HandlerEntry{
    .{ .tag = "health", .handler = healthHandler },
    .{ .tag = "sessions.list", .handler = sessionsListHandler },
    .{ .tag = "sessions.create", .handler = sessionsCreateHandler },
    .{ .tag = "sessions.get", .handler = sessionsGetHandler },
    .{ .tag = "sessions.delete", .handler = sessionsDeleteHandler },
    .{ .tag = "sessions.message", .handler = sessionsMessageHandler },
    .{ .tag = "sessions.turn", .handler = sessionsTurnHandler },
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
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const id = findParam(params, "id") orelse return error.BadRequest;

    // The mock runner takes the session_id verbatim as its session
    // identifier and echoes the input back. Production will parse the
    // request body JSON; the mock endpoint accepts any body and sends
    // a canned prompt through the runner so the counter round-trips.
    const result = ctx.runner.run(.{ .session_id = id, .input = "ping" }) catch |err| switch (err) {
        error.SessionMissing => return http.Response.notFound(),
        error.BudgetExceeded => return .{ .status = .too_many_requests, .body = "budget exceeded\n" },
        else => return error.InternalServerError,
    };

    _ = result;
    return http.Response.jsonOk("{\"status\":\"ok\"}");
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

fn runDelete(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .DELETE, .target = "/sessions/s1", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id returns 204" {
    try withMockContext(runDelete);
}
