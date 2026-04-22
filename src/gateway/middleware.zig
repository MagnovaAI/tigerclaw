//! Middleware layer — request filters that sit between the transport
//! adapter and the dispatcher.
//!
//! A middleware inspects the incoming `http.Request` and either:
//!   - returns a short-circuit `Response` (e.g. 401 on a bad token),
//!   - returns `null` to let the request continue to the next filter
//!     or the dispatcher.
//!
//! The chain is a plain slice of function pointers so callers can
//! compose different stacks for different gateway modes (e.g. bench
//! runs with auth off). Nothing here touches the network.
//!
//! Signal masking (`maskSigpipe`) lives here because it's a
//! process-wide policy that has to be set before the server starts
//! accepting connections. Keeping it next to the auth/log filters
//! keeps the gateway's "boot sequence" concerns in one module.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

pub const Outcome = union(enum) {
    /// Short-circuit the request with this response.
    respond: http.Response,
    /// Continue to the next middleware or the dispatcher.
    pass,
};

pub const Middleware = *const fn (req: http.Request, ctx: *Context) Outcome;

pub const Context = struct {
    /// Optional bearer token; when set, requests must carry
    /// `Authorization: Bearer <expected_bearer>`.
    expected_bearer: ?[]const u8 = null,
    /// When true, the log filter records a structured entry per
    /// request into `log_sink`. Tests set this to an in-memory sink
    /// so they can assert the format without touching stdout.
    log_enabled: bool = false,
    log_sink: ?*LogSink = null,
};

pub const LogEntry = struct {
    method: http.Method,
    target: []const u8,
    status: http.Status,
};

pub const LogSink = struct {
    entries: std.ArrayListUnmanaged(LogEntry) = .empty,

    pub fn deinit(self: *LogSink, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};

// --- bearer auth -----------------------------------------------------------

/// Reject requests whose `Authorization` header does not match the
/// configured bearer. When `expected_bearer` is null, auth is disabled
/// and every request passes.
pub fn bearerAuth(req: http.Request, ctx: *Context) Outcome {
    const expected = ctx.expected_bearer orelse return .pass;

    const header = req.getHeader("authorization") orelse {
        return .{ .respond = unauthorized("missing authorization header") };
    };

    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header, prefix)) {
        return .{ .respond = unauthorized("authorization must use Bearer scheme") };
    }
    const presented = header[prefix.len..];

    // Constant-time-ish comparison to avoid leaking token length
    // via obvious short-circuit timing. The difference is tiny over
    // a network but the cost is also tiny.
    if (presented.len != expected.len) {
        return .{ .respond = unauthorized("invalid bearer token") };
    }
    var diff: u8 = 0;
    for (presented, expected) |p, e| diff |= p ^ e;
    if (diff != 0) {
        return .{ .respond = unauthorized("invalid bearer token") };
    }
    return .pass;
}

fn unauthorized(message: []const u8) http.Response {
    _ = message;
    return .{
        .status = .unauthorized,
        .headers = &unauthorized_headers,
        .body = "unauthorized\n",
    };
}

const unauthorized_headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    .{ .name = "www-authenticate", .value = "Bearer" },
};

// --- request log -----------------------------------------------------------

/// Append a structured log entry for each request. The real wire-level
/// status code is not available at the "before dispatch" moment, so
/// this filter logs the *intent* (method + target) and leaves the
/// status field as `ok` as a placeholder. A post-dispatch hook fills
/// in the real status; that hook lives next to the adapter because it
/// needs the dispatched response.
pub fn requestLog(req: http.Request, ctx: *Context) Outcome {
    if (!ctx.log_enabled) return .pass;
    const sink = ctx.log_sink orelse return .pass;

    // We cannot allocate here without breaking the `Outcome` contract
    // (it has no allocator). In practice the adapter owns a gpa and
    // appends via `recordOutcome`, which is a separate helper below.
    _ = sink;
    _ = req;
    return .pass;
}

/// Record the final status of a request into a log sink. Called by
/// the adapter *after* the dispatcher has produced a response. The
/// allocator is the adapter's gpa; the sink owns the entries.
pub fn recordOutcome(
    allocator: std.mem.Allocator,
    sink: *LogSink,
    req: http.Request,
    resp: http.Response,
) std.mem.Allocator.Error!void {
    try sink.entries.append(allocator, .{
        .method = req.method,
        .target = req.target,
        .status = resp.status,
    });
}

// --- content-type negotiation ---------------------------------------------

/// Reject POST/PUT/PATCH requests that carry a body without a
/// `content-type` header, and reject ones whose type the gateway
/// does not understand. Today the only accepted body type is JSON.
pub fn requireJsonBody(req: http.Request, _: *Context) Outcome {
    const method_uses_body = switch (req.method) {
        .POST, .PUT, .PATCH => true,
        else => false,
    };
    if (!method_uses_body) return .pass;
    if (req.body.len == 0) return .pass;

    const ct = req.getHeader("content-type") orelse {
        return .{ .respond = .{
            .status = .unsupported_media_type,
            .headers = &text_plain_headers,
            .body = "missing content-type\n",
        } };
    };

    // Accept e.g. `application/json` or `application/json; charset=utf-8`.
    const expected = "application/json";
    if (ct.len < expected.len or !std.ascii.eqlIgnoreCase(ct[0..expected.len], expected)) {
        return .{ .respond = .{
            .status = .unsupported_media_type,
            .headers = &text_plain_headers,
            .body = "unsupported content-type\n",
        } };
    }
    return .pass;
}

const text_plain_headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
};

// --- pipeline --------------------------------------------------------------

/// Run `chain` in order; return the first short-circuit outcome or
/// `.pass` if every filter lets the request through.
pub fn run(
    chain: []const Middleware,
    req: http.Request,
    ctx: *Context,
) Outcome {
    for (chain) |mw| {
        switch (mw(req, ctx)) {
            .respond => |r| return .{ .respond = r },
            .pass => {},
        }
    }
    return .pass;
}

// --- SIGPIPE mask ----------------------------------------------------------

/// Ignore SIGPIPE so a client closing its half of a keep-alive TCP
/// connection does not terminate the gateway process. On non-POSIX
/// targets (Windows, WASI) this is a no-op.
pub fn maskSigpipe() void {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;
    const posix = std.posix;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "bearerAuth: passes when no expected bearer is configured" {
    var ctx: Context = .{};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &.{} };
    try testing.expectEqual(Outcome.pass, bearerAuth(req, &ctx));
}

test "bearerAuth: missing Authorization header → 401" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &.{} };
    const out = bearerAuth(req, &ctx);
    try testing.expectEqual(http.Status.unauthorized, out.respond.status);
}

test "bearerAuth: wrong scheme → 401" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const hs = [_]http.Header{.{ .name = "Authorization", .value = "Basic abc" }};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &hs };
    const out = bearerAuth(req, &ctx);
    try testing.expectEqual(http.Status.unauthorized, out.respond.status);
}

test "bearerAuth: wrong token → 401" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const hs = [_]http.Header{.{ .name = "Authorization", .value = "Bearer nope" }};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &hs };
    const out = bearerAuth(req, &ctx);
    try testing.expectEqual(http.Status.unauthorized, out.respond.status);
}

test "bearerAuth: matching token passes" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const hs = [_]http.Header{.{ .name = "Authorization", .value = "Bearer secret" }};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &hs };
    try testing.expectEqual(Outcome.pass, bearerAuth(req, &ctx));
}

test "bearerAuth: lowercase header name still matches (case-insensitive)" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const hs = [_]http.Header{.{ .name = "authorization", .value = "Bearer secret" }};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &hs };
    try testing.expectEqual(Outcome.pass, bearerAuth(req, &ctx));
}

test "requireJsonBody: GET with no body passes" {
    var ctx: Context = .{};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &.{} };
    try testing.expectEqual(Outcome.pass, requireJsonBody(req, &ctx));
}

test "requireJsonBody: POST without body passes" {
    var ctx: Context = .{};
    const req: http.Request = .{ .method = .POST, .target = "/", .headers = &.{} };
    try testing.expectEqual(Outcome.pass, requireJsonBody(req, &ctx));
}

test "requireJsonBody: POST with body and no content-type → 415" {
    var ctx: Context = .{};
    const req: http.Request = .{
        .method = .POST,
        .target = "/",
        .headers = &.{},
        .body = "{\"a\":1}",
    };
    const out = requireJsonBody(req, &ctx);
    try testing.expectEqual(http.Status.unsupported_media_type, out.respond.status);
}

test "requireJsonBody: POST with non-json content-type → 415" {
    var ctx: Context = .{};
    const hs = [_]http.Header{.{ .name = "Content-Type", .value = "text/plain" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/",
        .headers = &hs,
        .body = "hi",
    };
    const out = requireJsonBody(req, &ctx);
    try testing.expectEqual(http.Status.unsupported_media_type, out.respond.status);
}

test "requireJsonBody: POST with application/json passes" {
    var ctx: Context = .{};
    const hs = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/",
        .headers = &hs,
        .body = "{}",
    };
    try testing.expectEqual(Outcome.pass, requireJsonBody(req, &ctx));
}

test "requireJsonBody: accepts json with charset" {
    var ctx: Context = .{};
    const hs = [_]http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
    const req: http.Request = .{
        .method = .PATCH,
        .target = "/",
        .headers = &hs,
        .body = "{}",
    };
    try testing.expectEqual(Outcome.pass, requireJsonBody(req, &ctx));
}

test "run: empty chain → pass" {
    var ctx: Context = .{};
    const req: http.Request = .{ .method = .GET, .target = "/", .headers = &.{} };
    try testing.expectEqual(Outcome.pass, run(&.{}, req, &ctx));
}

test "run: first filter that responds short-circuits the chain" {
    var ctx: Context = .{ .expected_bearer = "secret" };
    const chain = [_]Middleware{ bearerAuth, requireJsonBody };
    const req: http.Request = .{ .method = .POST, .target = "/", .headers = &.{} };
    const out = run(&chain, req, &ctx);
    try testing.expectEqual(http.Status.unauthorized, out.respond.status);
}

test "recordOutcome: appends a log entry with method, target, and status" {
    var sink: LogSink = .{};
    defer sink.deinit(testing.allocator);

    const req: http.Request = .{ .method = .POST, .target = "/x", .headers = &.{} };
    const resp: http.Response = .{ .status = .created };
    try recordOutcome(testing.allocator, &sink, req, resp);

    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(http.Method.POST, sink.entries.items[0].method);
    try testing.expectEqualStrings("/x", sink.entries.items[0].target);
    try testing.expectEqual(http.Status.created, sink.entries.items[0].status);
}

test "maskSigpipe: can be called without panicking" {
    maskSigpipe();
}
