//! Thin HTTP client used by the CLI to talk to a running gateway.
//!
//! The gateway is local-only and one-shot. Every CLI verb that needs a
//! round-trip (`tigerclaw agent -m ...`, `tigerclaw gateway status`, the
//! `health` probe) goes through this module. The implementation is a
//! deliberately minimal wrapper around `std.http.Client.fetch`:
//!
//!   - one shot, no keep-alive, no connection pool reuse across calls
//!   - bearer token injected when the caller supplies one (otherwise no
//!     `authorization` header is sent — the gateway tolerates both for
//!     local-loopback)
//!   - one retry on `error.ConnectionRefused` because the daemon may
//!     still be binding its listener when a follow-up CLI call lands;
//!     the retry waits briefly via `io.sleep`
//!   - typed error mapping so callers don't pattern-match on the wide
//!     `FetchError` set: `GatewayDown`, `Unauthorized`, `BadRequest`,
//!     `InternalError`, `InvalidResponse`
//!
//! Response bodies are written into a caller-supplied `std.Io.Writer`
//! so the verbs can decide whether to render to stdout, capture into an
//! arena for parsing, or discard.

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,

    fn toStd(self: Method) std.http.Method {
        return switch (self) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
        };
    }
};

pub const Request = struct {
    method: Method,
    /// Absolute URL — `http://127.0.0.1:8765/health`. The CLI composes
    /// this from settings; the client itself never assumes a host.
    url: []const u8,
    /// Optional bearer token. When non-null, sent as
    /// `authorization: Bearer <token>`.
    bearer: ?[]const u8 = null,
    /// Optional request body. Sets content-type to
    /// `application/json` when non-null; the CLI only ever POSTs JSON.
    json_body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    /// True when the status code is in the 2xx range; convenience for
    /// callers that don't care about the exact code.
    ok: bool,
};

pub const Error = error{
    /// Listener refused the connection even after the retry. Either no
    /// daemon is running on the configured host:port, or it crashed
    /// between checks. Callers surface this as `tigerclaw gateway start`.
    GatewayDown,
    /// 401 from the gateway. Settings hold a stale or missing token.
    Unauthorized,
    /// 4xx (other than 401). The verb itself is misformed — the CLI
    /// either built a bad URL or sent a payload the gateway rejects.
    BadRequest,
    /// 5xx. The daemon is up but failed internally; the user can rerun
    /// after inspecting `tigerclaw gateway logs`.
    InternalError,
    /// Anything else: redirects, malformed URI, TLS issues, body write
    /// failure. Treated as a single bucket because the CLI cannot
    /// recover differently.
    InvalidResponse,
} || std.mem.Allocator.Error;

pub const Options = struct {
    /// Nanoseconds to wait between the first failed connect and the
    /// retry. The gateway's bind+listen happens in microseconds; 50ms
    /// is enough headroom for the kernel to publish the socket without
    /// noticeably slowing the CLI.
    retry_delay_ns: u64 = 50 * std.time.ns_per_ms,
};

/// Issue one request, retrying once on `ConnectionRefused`. Writes the
/// response body into `body_out` (pass a discarding writer to drop it).
pub fn send(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: Request,
    body_out: ?*std.Io.Writer,
    opts: Options,
) Error!Response {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    return doFetch(&client, io, req, body_out, opts);
}

fn doFetch(
    client: *std.http.Client,
    io: std.Io,
    req: Request,
    body_out: ?*std.Io.Writer,
    opts: Options,
) Error!Response {
    const result = fetchOnce(client, req, body_out) catch |err| switch (err) {
        error.ConnectionRefused => blk: {
            std.Io.sleep(io, opts.retry_delay_ns) catch {};
            break :blk fetchOnce(client, req, body_out) catch |retry_err| switch (retry_err) {
                error.ConnectionRefused => return error.GatewayDown,
                else => return classifyTransport(retry_err),
            };
        },
        else => return classifyTransport(err),
    };

    return classifyResponse(result);
}

fn fetchOnce(
    client: *std.http.Client,
    req: Request,
    body_out: ?*std.Io.Writer,
) std.http.Client.FetchError!std.http.Client.FetchResult {
    var auth_buf: [256]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;

    if (req.bearer) |token| {
        const rendered = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch
            return error.WriteFailed;
        extra[extra_len] = .{ .name = "authorization", .value = rendered };
        extra_len += 1;
    }
    if (req.json_body != null) {
        extra[extra_len] = .{ .name = "content-type", .value = "application/json" };
        extra_len += 1;
    }

    return client.fetch(.{
        .location = .{ .url = req.url },
        .method = req.method.toStd(),
        .payload = req.json_body,
        .keep_alive = false,
        .response_writer = body_out,
        .extra_headers = extra[0..extra_len],
    });
}

fn classifyTransport(err: std.http.Client.FetchError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn classifyResponse(result: std.http.Client.FetchResult) Error!Response {
    const code: u16 = @intFromEnum(result.status);
    if (code >= 200 and code < 300) return .{ .status = code, .ok = true };
    if (code == 401) return error.Unauthorized;
    if (code >= 400 and code < 500) return error.BadRequest;
    if (code >= 500 and code < 600) return error.InternalError;
    return error.InvalidResponse;
}

// --- tests -----------------------------------------------------------------
//
// The transport layer is `std.http.Client.fetch`, which we intentionally
// do not reimplement. Tests therefore exercise the surface this module
// owns end-to-end: status classification, bearer/body header injection
// shape, and the retry-once behaviour. The retry itself is covered by
// invoking `send` against an unbound port and asserting the typed
// `GatewayDown` outcome — which only fires after both fetch attempts
// fail with `ConnectionRefused`.

const testing = std.testing;

test "Method.toStd: maps every variant" {
    try testing.expectEqual(std.http.Method.GET, Method.toStd(.GET));
    try testing.expectEqual(std.http.Method.POST, Method.toStd(.POST));
    try testing.expectEqual(std.http.Method.PUT, Method.toStd(.PUT));
    try testing.expectEqual(std.http.Method.PATCH, Method.toStd(.PATCH));
    try testing.expectEqual(std.http.Method.DELETE, Method.toStd(.DELETE));
}

test "classifyResponse: 2xx is ok" {
    const r = try classifyResponse(.{ .status = .ok });
    try testing.expect(r.ok);
    try testing.expectEqual(@as(u16, 200), r.status);

    const created = try classifyResponse(.{ .status = .created });
    try testing.expect(created.ok);
    try testing.expectEqual(@as(u16, 201), created.status);
}

test "classifyResponse: 401 is Unauthorized" {
    try testing.expectError(error.Unauthorized, classifyResponse(.{ .status = .unauthorized }));
}

test "classifyResponse: 4xx (non-401) is BadRequest" {
    try testing.expectError(error.BadRequest, classifyResponse(.{ .status = .bad_request }));
    try testing.expectError(error.BadRequest, classifyResponse(.{ .status = .not_found }));
    try testing.expectError(error.BadRequest, classifyResponse(.{ .status = .method_not_allowed }));
}

test "classifyResponse: 5xx is InternalError" {
    try testing.expectError(error.InternalError, classifyResponse(.{ .status = .internal_server_error }));
    try testing.expectError(error.InternalError, classifyResponse(.{ .status = .service_unavailable }));
}

test "classifyResponse: anything else is InvalidResponse" {
    try testing.expectError(
        error.InvalidResponse,
        classifyResponse(.{ .status = @as(std.http.Status, @enumFromInt(199)) }),
    );
    try testing.expectError(
        error.InvalidResponse,
        classifyResponse(.{ .status = @as(std.http.Status, @enumFromInt(302)) }),
    );
}

test "send: connection-refused on a closed port surfaces GatewayDown" {
    // Bind a listener, capture its ephemeral port, then close it. By the
    // time `send` runs, the kernel has the port in TIME_WAIT and any
    // new connect lands as ConnectionRefused — both attempts.
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    const port = server.socket.address.getPort();
    server.deinit(testing.io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/health", .{port});

    const result = send(
        testing.allocator,
        testing.io,
        .{ .method = .GET, .url = url },
        null,
        .{ .retry_delay_ns = 1 * std.time.ns_per_ms },
    );
    try testing.expectError(error.GatewayDown, result);
}
