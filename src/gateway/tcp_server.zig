//! TCP server adapter that binds `std.http.Server` to the gateway
//! dispatcher.
//!
//! This is the only module in the gateway subsystem that touches real
//! sockets. Everything else (`router`, `http`, `dispatcher`,
//! `middleware`, `routes`) is transport-neutral and unit-tested in
//! isolation. Here we:
//!
//!   1. Bind a TCP listener via `std.Io.net.IpAddress.listen`.
//!   2. In a loop: `accept` → wrap the stream in `std.http.Server` →
//!      `receiveHead` → translate to `gateway.http.Request` →
//!      `dispatcher.dispatch` → `request.respond` with the response.
//!   3. Honour an atomic shutdown flag so signal handlers can ask the
//!      loop to drain and exit between connections.
//!
//! The connection model is intentionally one-shot per accept: each
//! request is read, dispatched, responded, and the socket is closed.
//! Keep-alive and pipelining are not implemented in beta — the daemon
//! handles request volume by being a local-only control plane, not a
//! production HTTP server.
//!
//! Signal handlers are installed via `installShutdownHandlers` which
//! points SIGINT and SIGTERM at the shared `should_stop` flag. Tests
//! drive shutdown by calling `requestStop` directly so they do not
//! need to send signals to themselves.

const std = @import("std");
const builtin = @import("builtin");
const router = @import("router.zig");
const http = @import("http.zig");
const dispatcher = @import("dispatcher.zig");

/// Process-wide stop flag. The accept loop reads it between
/// connections; signal handlers and tests set it to ask the server to
/// drain and exit. Atomic so handlers (which run on an arbitrary
/// thread / signal context) can write it safely.
pub var should_stop: std.atomic.Value(bool) = .init(false);

pub fn requestStop() void {
    should_stop.store(true, .release);
}

pub fn resetStopForTesting() void {
    should_stop.store(false, .release);
}

pub const ServeError = error{
    BindFailed,
    AcceptFailed,
} || std.mem.Allocator.Error;

pub const ServeOptions = struct {
    /// Soft cap on a single request's headers + start-line. Bodies are
    /// read separately up to `max_body_bytes`.
    head_buffer_bytes: usize = 16 * 1024,
    /// Soft cap on a single request body. Anything beyond this is
    /// truncated and the dispatcher sees the truncated bytes; the
    /// gateway is local-only so we don't bother with 413 framing here.
    max_body_bytes: usize = 1 * 1024 * 1024,
    /// Headers we forward into `http.Request.headers`. The full HTTP
    /// header set can be large; the dispatcher cares about a small
    /// fixed slice. Anything beyond this many headers is dropped.
    max_request_headers: usize = http.max_request_headers,
};

/// Bind, accept, dispatch. Returns when `should_stop` is observed
/// true between connections, or when the listener errors fatally.
pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: *const std.Io.net.IpAddress,
    routes: []const router.Route,
    handlers: dispatcher.HandlerMap,
    opts: ServeOptions,
) ServeError!void {
    var server = address.listen(io, .{ .reuse_address = true }) catch return error.BindFailed;
    defer server.deinit(io);

    while (!should_stop.load(.acquire)) {
        var stream = server.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            error.SocketNotListening => return,
            else => return error.AcceptFailed,
        };
        defer stream.close(io);

        handleConnection(allocator, io, &stream, routes, handlers, opts) catch {
            // Per-connection failures are intentionally swallowed; the
            // server stays up. A future commit can plumb a structured
            // log sink so each failure becomes a daemon log line.
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    routes: []const router.Route,
    handlers: dispatcher.HandlerMap,
    opts: ServeOptions,
) !void {
    const head_buf = try allocator.alloc(u8, opts.head_buffer_bytes);
    defer allocator.free(head_buf);
    const out_buf = try allocator.alloc(u8, 4 * 1024);
    defer allocator.free(out_buf);

    var s_reader = stream.reader(io, head_buf);
    var s_writer = stream.writer(io, out_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;

    const method = mapMethod(request.head.method) orelse {
        try respondStatus(&request, .method_not_allowed, "method not allowed\n");
        return;
    };

    var headers_buf: [http.max_request_headers]http.Header = undefined;
    var headers_len: usize = 0;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (headers_len == opts.max_request_headers or headers_len == headers_buf.len) break;
        headers_buf[headers_len] = .{ .name = h.name, .value = h.value };
        headers_len += 1;
    }

    // Body reads in 0.16 require a dedicated buffer that survives the
    // dispatch call. We always read into a heap buffer sized at most
    // `max_body_bytes`. Empty / no-content requests yield a zero-length
    // slice which is what the dispatcher expects by default.
    var body_storage: []u8 = &.{};
    defer if (body_storage.len > 0) allocator.free(body_storage);
    if (request.head.content_length) |clen| {
        const want: usize = @min(@as(usize, @intCast(clen)), opts.max_body_bytes);
        if (want > 0) {
            body_storage = try allocator.alloc(u8, want);
            const body_reader = request.readerExpectNone(body_storage);
            const n = body_reader.readSliceShort(body_storage) catch want;
            body_storage = body_storage[0..n];
        }
    }

    const our_req: http.Request = .{
        .method = method,
        .target = request.head.target,
        .headers = headers_buf[0..headers_len],
        .body = body_storage,
    };

    const resp = dispatcher.dispatch(routes, handlers, our_req) catch |err| switch (err) {
        error.HandlerMissing, error.InternalServerError => {
            try respondStatus(&request, .internal_server_error, "internal error\n");
            return;
        },
        error.BadRequest => {
            try respondStatus(&request, .bad_request, "bad request\n");
            return;
        },
        error.TooManyParams => {
            try respondStatus(&request, .bad_request, "too many path params\n");
            return;
        },
    };

    try respondResolved(&request, resp);
}

fn respondResolved(request: *std.http.Server.Request, resp: http.Response) !void {
    var extra_buf: [http.max_response_headers]std.http.Header = undefined;
    const extra_len = @min(resp.headers.len, extra_buf.len);
    for (resp.headers[0..extra_len], 0..) |h, i| {
        extra_buf[i] = .{ .name = h.name, .value = h.value };
    }
    request.respond(resp.body, .{
        .status = mapStatus(resp.status),
        .keep_alive = false,
        .extra_headers = extra_buf[0..extra_len],
    }) catch return;
}

fn respondStatus(
    request: *std.http.Server.Request,
    status: http.Status,
    body: []const u8,
) !void {
    request.respond(body, .{
        .status = mapStatus(status),
        .keep_alive = false,
    }) catch return;
}

fn mapMethod(m: std.http.Method) ?router.Method {
    return switch (m) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        else => null,
    };
}

fn mapStatus(s: http.Status) std.http.Status {
    return @enumFromInt(@intFromEnum(s));
}

// --- signal handling -------------------------------------------------------

/// Install POSIX SIGINT/SIGTERM handlers that point at `should_stop`.
/// No-op on Windows / WASI where signals don't exist in this form.
pub fn installShutdownHandlers() void {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn handleSignal(_: std.c.SIG) callconv(.c) void {
    should_stop.store(true, .release);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn pingHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
) dispatcher.HandlerError!http.Response {
    return http.Response.jsonOk("{\"pong\":true}");
}

fn echoBodyHandler(
    req: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
) dispatcher.HandlerError!http.Response {
    return .{
        .status = .ok,
        .body = req.body,
    };
}

const test_routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/ping", .tag = "ping" },
    .{ .method = .POST, .pattern = "/echo", .tag = "echo" },
};

const test_handlers = [_]dispatcher.HandlerEntry{
    .{ .tag = "ping", .handler = pingHandler },
    .{ .tag = "echo", .handler = echoBodyHandler },
};

const ServeArgs = struct {
    io: std.Io,
    address: *const std.Io.net.IpAddress,
};

fn serveThread(args: *ServeArgs) void {
    serve(
        testing.allocator,
        args.io,
        args.address,
        &test_routes,
        &test_handlers,
        .{},
    ) catch {};
}

test "mapMethod: covers the methods the router speaks" {
    try testing.expectEqual(@as(?router.Method, .GET), mapMethod(.GET));
    try testing.expectEqual(@as(?router.Method, .POST), mapMethod(.POST));
    try testing.expectEqual(@as(?router.Method, .PUT), mapMethod(.PUT));
    try testing.expectEqual(@as(?router.Method, .PATCH), mapMethod(.PATCH));
    try testing.expectEqual(@as(?router.Method, .DELETE), mapMethod(.DELETE));
    try testing.expectEqual(@as(?router.Method, null), mapMethod(.OPTIONS));
}

test "mapStatus: numeric values round-trip" {
    try testing.expectEqual(@as(u16, 200), @intFromEnum(mapStatus(.ok)));
    try testing.expectEqual(@as(u16, 404), @intFromEnum(mapStatus(.not_found)));
    try testing.expectEqual(@as(u16, 405), @intFromEnum(mapStatus(.method_not_allowed)));
    try testing.expectEqual(@as(u16, 500), @intFromEnum(mapStatus(.internal_server_error)));
}

test "requestStop / resetStopForTesting toggle the flag" {
    resetStopForTesting();
    try testing.expect(!should_stop.load(.acquire));
    requestStop();
    try testing.expect(should_stop.load(.acquire));
    resetStopForTesting();
    try testing.expect(!should_stop.load(.acquire));
}
