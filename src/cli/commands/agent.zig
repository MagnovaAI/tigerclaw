//! `tigerclaw agent` — POST a turn to the gateway and render token
//! events to stdout.
//!
//! The verb takes an optional session id (`--session <id>`, defaults
//! to `mock-session`), composes a `POST /sessions/<id>/turns` against
//! the gateway with `Accept: text/event-stream`, and parses the SSE
//! response into per-token writes on stdout. A SIGINT handler sets a
//! shared atomic flag; if it fires before the response is captured,
//! the verb posts `DELETE /sessions/<id>/turns/current` to ask the
//! gateway to cancel the in-flight react loop and exits with a
//! non-zero status so shell scripts can react.
//!
//! v0.1.0 caveat: the gateway buffers the SSE body before responding
//! (the dispatcher returns one Response value), so Ctrl-C arrives at
//! the verb either before the POST finishes or after — never mid
//! stream. The DELETE fires on the post-finish path so the gateway
//! still observes the cancel intent and can release the next turn's
//! state. Mid-stream interrupts arrive once the dispatcher gains a
//! streaming response shape in v0.2.0.

const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client.zig");

pub const Options = struct {
    /// Base URL for the gateway, e.g. `http://127.0.0.1:8765`.
    base_url: []const u8,
    /// Session to POST the turn to.
    session_id: []const u8 = "mock-session",
    /// Optional bearer token forwarded as `authorization: Bearer ...`.
    bearer: ?[]const u8 = null,
    /// Where to render decoded token text. Provided so tests can
    /// substitute a buffer without touching stdout.
    out: *std.Io.Writer,
};

pub const Error = error{
    GatewayDown,
    Unauthorized,
    BadRequest,
    InternalError,
    InvalidResponse,
    Interrupted,
    UrlTooLong,
} || std.mem.Allocator.Error;

/// Process-wide flag flipped by the SIGINT handler. Atomic so the
/// handler can write it from a signal context. Tests drive it
/// directly via `requestInterruptForTesting`.
pub var interrupt_requested: std.atomic.Value(bool) = .init(false);

pub fn requestInterruptForTesting() void {
    interrupt_requested.store(true, .release);
}

pub fn resetInterruptForTesting() void {
    interrupt_requested.store(false, .release);
}

/// Install the SIGINT handler that flips `interrupt_requested`. No-op
/// on Windows / WASI where the signal model doesn't apply.
pub fn installInterruptHandler() void {
    if (builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn handleSigint(_: std.c.SIG) callconv(.c) void {
    interrupt_requested.store(true, .release);
}

/// POST a turn and render the SSE body. Honours `interrupt_requested`
/// after the response lands; on interrupt, fires the cancel DELETE.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
) Error!void {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/{s}/turns",
        .{ opts.base_url, opts.session_id },
    ) catch return error.UrlTooLong;

    var body_buf: [16 * 1024]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const send_result = http_client.send(
        allocator,
        io,
        .{
            .method = .POST,
            .url = url,
            .bearer = opts.bearer,
            // Empty JSON body is what the mock endpoint accepts; the
            // mock runner uses a fixed prompt regardless of payload.
            .json_body = "{}",
        },
        &body_writer,
        .{},
    );

    const result = send_result catch |err| switch (err) {
        error.GatewayDown,
        error.Unauthorized,
        error.BadRequest,
        error.InternalError,
        error.InvalidResponse,
        error.OutOfMemory,
        => |e| return e,
    };
    _ = result;

    if (interrupt_requested.load(.acquire)) {
        // Best-effort cancel; the gateway treats it as idempotent.
        cancelTurn(allocator, io, opts.base_url, opts.session_id, opts.bearer) catch {};
        return error.Interrupted;
    }

    try renderSse(opts.out, body_writer.buffered());
}

/// Fire DELETE /sessions/:id/turns/current. Surfaced separately so the
/// SIGINT path can call it without re-running the whole verb.
pub fn cancelTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    bearer: ?[]const u8,
) Error!void {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/{s}/turns/current",
        .{ base_url, session_id },
    ) catch return error.UrlTooLong;

    _ = http_client.send(
        allocator,
        io,
        .{ .method = .DELETE, .url = url, .bearer = bearer },
        null,
        .{},
    ) catch |err| switch (err) {
        error.GatewayDown,
        error.Unauthorized,
        error.BadRequest,
        error.InternalError,
        error.InvalidResponse,
        error.OutOfMemory,
        => |e| return e,
    };
}

/// Walk the SSE body in `body` and write the `data:` payload of every
/// `event: token` event to `out`. Terminates on a `done` event or end
/// of input. Tolerates trailing whitespace and empty lines per the SSE
/// grammar — matches what the gateway emits.
pub fn renderSse(out: *std.Io.Writer, body: []const u8) Error!void {
    var it = std.mem.splitSequence(u8, body, "\n\n");
    while (it.next()) |frame| {
        var event_name: []const u8 = "message";
        var data: []const u8 = "";

        var lines = std.mem.splitScalar(u8, frame, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "event:")) {
                event_name = std.mem.trim(u8, trimmed[6..], " \t");
            } else if (std.mem.startsWith(u8, trimmed, "data:")) {
                data = std.mem.trim(u8, trimmed[5..], " \t");
            }
        }

        if (std.mem.eql(u8, event_name, "token")) {
            out.writeAll(data) catch return error.InvalidResponse;
        } else if (std.mem.eql(u8, event_name, "done")) {
            return;
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "renderSse: writes the data of every token event in order" {
    const body =
        "event: token\ndata: hello\n\n" ++
        "event: token\ndata:  world\n\n" ++
        "event: done\ndata: {\"completed\":true}\n\n";

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderSse(&w, body);
    try testing.expectEqualStrings("hello world", w.buffered());
}

test "renderSse: stops at the done event" {
    const body =
        "event: token\ndata: a\n\n" ++
        "event: done\ndata: {}\n\n" ++
        "event: token\ndata: must-not-appear\n\n";

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderSse(&w, body);
    try testing.expectEqualStrings("a", w.buffered());
}

test "renderSse: ignores unknown event types" {
    const body =
        "event: ping\ndata: ignore\n\n" ++
        "event: token\ndata: kept\n\n";

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderSse(&w, body);
    try testing.expectEqualStrings("kept", w.buffered());
}

test "interrupt_requested: testing helpers toggle the flag" {
    resetInterruptForTesting();
    try testing.expect(!interrupt_requested.load(.acquire));
    requestInterruptForTesting();
    try testing.expect(interrupt_requested.load(.acquire));
    resetInterruptForTesting();
    try testing.expect(!interrupt_requested.load(.acquire));
}
