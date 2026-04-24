//! Request → Response dispatcher.
//!
//! Ties the router (`router.zig`) to the transport-neutral HTTP types
//! (`http.zig`). A `HandlerMap` is a small array of `{ tag, fn }`
//! entries; the dispatcher resolves the incoming request against a
//! route table, then invokes the handler whose tag matches the
//! route's tag.
//!
//! This is still pure: no network, no threads. The real TCP server
//! wires `std.http.Server` to `dispatch` in a later commit.

const std = @import("std");
const router = @import("router.zig");
const http = @import("http.zig");

pub const HandlerError = error{
    BadRequest,
    InternalServerError,
};

/// Opaque stream hook: a pointer to the underlying
/// `std.http.Server.Request` when the gateway is running against a
/// real TCP connection, null when the dispatcher is being driven by
/// in-process tests. Handlers that want to stream a chunked body
/// (SSE, long-running downloads) can cast this back via
/// `streaming.cast()` and call `respondStreaming` directly. When a
/// handler has responded via the stream hook it must return
/// `streaming_handled_sentinel` so the tcp_server skips the
/// buffered-response path.
pub const StreamHook = ?*anyopaque;

/// Handlers receive the request plus the matched route parameters
/// and an optional stream hook. Return an in-process `http.Response`;
/// if the handler used the stream hook to respond, it must return
/// `http.Response.streamingHandled()` so the caller knows not to
/// write a second response.
pub const Handler = *const fn (
    req: http.Request,
    params: []const router.Param,
    tail: ?[]const u8,
    stream_hook: StreamHook,
) HandlerError!http.Response;

pub const HandlerEntry = struct {
    tag: []const u8,
    handler: Handler,
};

pub const HandlerMap = []const HandlerEntry;

pub const DispatchError = error{
    TooManyParams,
    HandlerMissing,
} || HandlerError;

pub fn dispatch(
    routes: []const router.Route,
    handlers: HandlerMap,
    req: http.Request,
    stream_hook: StreamHook,
) DispatchError!http.Response {
    var params_buffer: [router.max_params]router.Param = undefined;
    const resolved = try router.resolve(routes, req.method, req.target, &params_buffer);

    switch (resolved) {
        .match => |m| {
            for (handlers) |entry| {
                if (std.mem.eql(u8, entry.tag, m.route.tag)) {
                    return entry.handler(req, m.params, m.tail, stream_hook);
                }
            }
            return error.HandlerMissing;
        },
        .method_not_allowed => {
            // Caller is responsible for serialising the Allow header
            // because the `allowed` slice lives on the stack frame of
            // `router.resolve`. Here we just surface a 405 with a
            // generic body; a richer Allow-aware path can be added in
            // a middleware layer.
            return .{
                .status = .method_not_allowed,
                .body = "method not allowed\n",
            };
        },
        .no_match => return http.Response.notFound(),
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const canned_ok_body = "{\"ok\":true}";

fn healthHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: StreamHook,
) HandlerError!http.Response {
    return http.Response.jsonOk(canned_ok_body);
}

fn echoIdHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: StreamHook,
) HandlerError!http.Response {
    // Verify the dispatcher forwarded the captured :id param.
    for (params) |p| {
        if (std.mem.eql(u8, p.name, "id")) {
            return http.Response.jsonOk(p.value);
        }
    }
    return error.BadRequest;
}

const test_routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/health", .tag = "health" },
    .{ .method = .GET, .pattern = "/sessions/:id", .tag = "sessions.get" },
};

const test_handlers = [_]HandlerEntry{
    .{ .tag = "health", .handler = healthHandler },
    .{ .tag = "sessions.get", .handler = echoIdHandler },
};

test "dispatch: literal route invokes the matching handler" {
    const req: http.Request = .{ .method = .GET, .target = "/health", .headers = &.{} };
    const resp = try dispatch(&test_routes, &test_handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings(canned_ok_body, resp.body);
}

test "dispatch: param route forwards captured params to the handler" {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/abc-123", .headers = &.{} };
    const resp = try dispatch(&test_routes, &test_handlers, req, null);
    try testing.expectEqualStrings("abc-123", resp.body);
}

test "dispatch: unknown path returns 404 from Response.notFound" {
    const req: http.Request = .{ .method = .GET, .target = "/missing", .headers = &.{} };
    const resp = try dispatch(&test_routes, &test_handlers, req, null);
    try testing.expectEqual(http.Status.not_found, resp.status);
}

test "dispatch: wrong method returns a 405 body" {
    const req: http.Request = .{ .method = .DELETE, .target = "/health", .headers = &.{} };
    const resp = try dispatch(&test_routes, &test_handlers, req, null);
    try testing.expectEqual(http.Status.method_not_allowed, resp.status);
}

test "dispatch: missing handler tag surfaces HandlerMissing" {
    const routes = [_]router.Route{
        .{ .method = .GET, .pattern = "/orphan", .tag = "orphan" },
    };
    const req: http.Request = .{ .method = .GET, .target = "/orphan", .headers = &.{} };
    try testing.expectError(
        error.HandlerMissing,
        dispatch(&routes, &test_handlers, req, null),
    );
}
