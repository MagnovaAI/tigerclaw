//! Transport-neutral request/response types the dispatcher consumes.
//!
//! The gateway receives requests from a `std.http.Server` bound to a
//! real TCP socket, but the dispatcher itself should not care about
//! sockets. This module defines the shape the routing/handler layer
//! operates on: an owned `Request` value (method, path, headers, body
//! bytes) and a `Response` struct the handler fills in (status, headers,
//! body bytes).
//!
//! All memory is caller-allocated. Handlers never touch TCP directly;
//! tests construct a `Request` in-process and assert the handler's
//! `Response`. A thin adapter in a later commit converts between
//! `std.http.Server.Request` / `Response` and these types.

const std = @import("std");
const router = @import("router.zig");

pub const Method = router.Method;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const max_request_headers = 32;
pub const max_response_headers = 16;

pub const Request = struct {
    method: Method,
    /// Full request target (path + optional query). The router strips
    /// the query before matching; handlers can parse it via
    /// `queryString` below.
    target: []const u8,
    headers: []const Header,
    body: []const u8 = "",

    /// Returns the substring after `?`, or null if the target has no
    /// query. The slice aliases the original target.
    pub fn queryString(self: Request) ?[]const u8 {
        const q = std.mem.indexOfScalar(u8, self.target, '?') orelse return null;
        return self.target[q + 1 ..];
    }

    /// Case-insensitive header lookup. Returns the first matching
    /// value or null. The match is ASCII-only which is sufficient for
    /// standard HTTP header names.
    pub fn getHeader(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    unsupported_media_type = 415,
    too_many_requests = 429,
    internal_server_error = 500,
    service_unavailable = 503,

    pub fn phrase(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .unsupported_media_type => "Unsupported Media Type",
            .too_many_requests => "Too Many Requests",
            .internal_server_error => "Internal Server Error",
            .service_unavailable => "Service Unavailable",
        };
    }
};

pub const Response = struct {
    status: Status,
    /// Zero or more response headers. The adapter serialises these
    /// verbatim; content-type + content-length are included here, not
    /// injected by the adapter.
    headers: []const Header = &.{},
    body: []const u8 = "",

    pub fn jsonOk(body: []const u8) Response {
        return .{
            .status = .ok,
            .headers = &default_json_headers,
            .body = body,
        };
    }

    pub fn notFound() Response {
        return .{
            .status = .not_found,
            .headers = &default_text_headers,
            .body = "not found\n",
        };
    }

    /// Build a 405 response. The caller owns the `headers` slice
    /// because the `allow` value must live for the same lifetime as
    /// the returned Response — a `&[_]Header{...}` initialiser inside
    /// this function would point at a stack-local array by the time
    /// the caller wrote the response.
    pub fn methodNotAllowed(headers: []const Header) Response {
        return .{
            .status = .method_not_allowed,
            .headers = headers,
            .body = "method not allowed\n",
        };
    }
};

const default_json_headers = [_]Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
};

const default_text_headers = [_]Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

/// Render the HTTP/1.1 status-line + headers + blank-separator into
/// the writer. Does *not* write the body; callers decide whether to
/// stream. Useful for SSE responses and for tests that want to verify
/// framing.
pub fn writeStatusAndHeaders(
    w: *std.Io.Writer,
    resp: Response,
) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(resp.status), resp.status.phrase() });
    for (resp.headers) |h| {
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try w.writeAll("\r\n");
}

/// Render a full non-streaming response (status + headers + body).
pub fn writeResponse(
    w: *std.Io.Writer,
    resp: Response,
) std.Io.Writer.Error!void {
    try writeStatusAndHeaders(w, resp);
    if (resp.body.len > 0) try w.writeAll(resp.body);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Request.queryString: present" {
    const r: Request = .{
        .method = .GET,
        .target = "/sessions/abc?follow=true",
        .headers = &.{},
    };
    try testing.expect(r.queryString() != null);
    try testing.expectEqualStrings("follow=true", r.queryString().?);
}

test "Request.queryString: absent" {
    const r: Request = .{
        .method = .GET,
        .target = "/health",
        .headers = &.{},
    };
    try testing.expect(r.queryString() == null);
}

test "Request.getHeader: case-insensitive" {
    const hs = [_]Header{
        .{ .name = "Authorization", .value = "Bearer abc" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const r: Request = .{ .method = .GET, .target = "/", .headers = &hs };
    try testing.expectEqualStrings("Bearer abc", r.getHeader("authorization").?);
    try testing.expectEqualStrings("application/json", r.getHeader("CONTENT-TYPE").?);
    try testing.expect(r.getHeader("missing") == null);
}

test "Response.jsonOk: produces a 200 + JSON content-type" {
    const r = Response.jsonOk("{\"ok\":true}");
    try testing.expectEqual(Status.ok, r.status);
    try testing.expectEqual(@as(usize, 1), r.headers.len);
    try testing.expectEqualStrings("application/json; charset=utf-8", r.headers[0].value);
}

test "writeResponse: emits status-line, headers, blank line, body" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, Response.jsonOk("{\"a\":1}"));
    const out = w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\r\ncontent-type: application/json; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n{\"a\":1}"));
}

test "writeResponse: method not allowed includes Allow header" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const headers = [_]Header{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "allow", .value = "GET, POST" },
    };
    try writeResponse(&w, Response.methodNotAllowed(&headers));
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 405 Method Not Allowed\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "allow: GET, POST\r\n") != null);
}

test "writeStatusAndHeaders: does not write the body" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStatusAndHeaders(&w, .{
        .status = .ok,
        .headers = &[_]Header{.{ .name = "x-test", .value = "1" }},
        .body = "will-not-appear",
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "will-not-appear") == null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}
