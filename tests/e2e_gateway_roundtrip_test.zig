//! End-to-end: gateway TCP server adapter against the CLI HTTP client.
//!
//! Boots the production `gateway.tcp_server.serve` accept loop on a
//! loopback ephemeral port in a background thread, then drives a real
//! HTTP request through `cli.commands.http_client.send` over a TCP
//! socket. This is the first place those two halves meet for real —
//! every other test exercises one side with the other mocked. If this
//! test breaks, `tigerclaw gateway start` followed by any CLI verb that
//! calls home is broken.
//!
//! Shutdown is driven by flipping the server's atomic stop flag and
//! then making a no-op connect to wake the parked `accept` call (the
//! production loop only checks the flag between connections). The flag
//! is reset in `defer` so subsequent tests in the same binary aren't
//! poisoned.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const gateway = tigerclaw.gateway;
const http_client = tigerclaw.cli.commands.http_client;

fn pingHandler(
    _: gateway.http.Request,
    _: []const gateway.router.Param,
    _: ?[]const u8,
) gateway.dispatcher.HandlerError!gateway.http.Response {
    return gateway.http.Response.jsonOk("{\"pong\":true}");
}

const routes = [_]gateway.router.Route{
    .{ .method = .GET, .pattern = "/ping", .tag = "ping" },
};

const handlers = [_]gateway.dispatcher.HandlerEntry{
    .{ .tag = "ping", .handler = pingHandler },
};

const ServeArgs = struct {
    io: std.Io,
    address: *const std.Io.net.IpAddress,
};

fn serveThread(args: *ServeArgs) void {
    // Per-connection failures are swallowed by `serve`; a fatal bind /
    // accept error returns out of the loop and ends the thread quietly.
    gateway.tcp_server.serve(
        testing.allocator,
        args.io,
        args.address,
        &routes,
        &handlers,
        .{},
    ) catch {};
}

test "e2e gateway roundtrip: TCP server adapter answers the CLI HTTP client" {
    gateway.tcp_server.resetStopForTesting();

    // Discover a free loopback port by binding with port 0, reading the
    // assigned port, then closing. The production `serve` will rebind
    // the same port a moment later — the small race is absorbed by the
    // CLI client's retry-on-ConnectionRefused.
    const probe_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var probe = try probe_addr.listen(testing.io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(testing.io);

    const serve_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var args: ServeArgs = .{ .io = testing.io, .address = &serve_addr };

    const thread = try std.Thread.spawn(.{}, serveThread, .{&args});

    // Always tear the server down even if assertions fail. Order:
    //   1. flip the stop flag so the loop exits after the next accept,
    //   2. fire one no-op connect to unblock the parked accept,
    //   3. join the background thread,
    //   4. reset the global flag so neighbouring tests stay clean.
    defer {
        gateway.tcp_server.requestStop();
        if (serve_addr.connect(testing.io, .{ .mode = .stream, .protocol = .tcp })) |s| {
            var wake = s;
            wake.close(testing.io);
        } else |_| {}
        thread.join();
        gateway.tcp_server.resetStopForTesting();
    }

    // No artificial grace period — correctness rides on the client's
    // built-in retry-on-ConnectionRefused, which fires if our request
    // beats the server's bind+listen.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/ping", .{port});

    var body_buf: [256]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const result = try http_client.send(
        testing.allocator,
        testing.io,
        .{ .method = .GET, .url = url },
        &body_writer,
        .{},
    );

    try testing.expect(result.ok);
    try testing.expectEqual(@as(u16, 200), result.status);

    const body = body_writer.buffered();
    try testing.expect(std.mem.indexOf(u8, body, "\"pong\":true") != null);
}
