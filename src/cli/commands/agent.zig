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
    /// Configured agent name (`tigerclaw agent <name> -m ...`).
    agent_name: []const u8 = "default",
    /// User-facing message. Empty means "no payload" (the mock runner
    /// echoes regardless; live runners receive it as the user turn).
    message: []const u8 = "",
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

    // Build the JSON body. Mock runner ignores it; live runners read
    // `agent` + `message`. Body is heap-allocated through the arena so
    // it survives the http_client.send call.
    const body_json = try std.json.Stringify.valueAlloc(allocator, .{
        .agent = opts.agent_name,
        .message = opts.message,
    }, .{});
    defer allocator.free(body_json);

    var body_buf: [16 * 1024]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const send_result = http_client.send(
        allocator,
        io,
        .{
            .method = .POST,
            .url = url,
            .bearer = opts.bearer,
            .json_body = body_json,
            // Opt the gateway into the SSE response shape so the
            // renderer below has token events to walk.
            .accept = "text/event-stream",
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
    // Trailing newline so the shell prompt lands on the next line —
    // the SSE token frames carry no terminator of their own.
    opts.out.writeAll("\n") catch return error.InvalidResponse;
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
/// `event: token` event to `out`. Consecutive token events are joined
/// with `\n` — the gateway splits multi-line replies into one frame
/// per source line (SSE disallows literal newlines in `data:`) and
/// relies on the client to reinsert them. Terminates on a `done` event
/// or end of input.
pub fn renderSse(out: *std.Io.Writer, body: []const u8) Error!void {
    var it = std.mem.splitSequence(u8, body, "\n\n");
    var token_seen: bool = false;
    while (it.next()) |frame| {
        var event_name: []const u8 = "message";
        var data: []const u8 = "";
        var had_data: bool = false;

        var lines = std.mem.splitScalar(u8, frame, '\n');
        while (lines.next()) |line| {
            // Trim only the CR so trailing spaces in `data:` survive.
            const clean = std.mem.trimEnd(u8, line, "\r");
            if (clean.len == 0) continue;
            if (std.mem.startsWith(u8, clean, "event:")) {
                event_name = std.mem.trim(u8, clean[6..], " \t");
            } else if (std.mem.startsWith(u8, clean, "data:")) {
                // Strip the single optional space after the colon per
                // the SSE grammar; keep everything else verbatim.
                var payload = clean[5..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                data = payload;
                had_data = true;
            }
        }

        if (std.mem.eql(u8, event_name, "token") and had_data) {
            if (token_seen) out.writeAll("\n") catch return error.InvalidResponse;
            out.writeAll(data) catch return error.InvalidResponse;
            token_seen = true;
        } else if (std.mem.eql(u8, event_name, "done")) {
            return;
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "renderSse: joins consecutive token frames with newlines" {
    // Gateway splits multi-line replies into one frame per source
    // line; the client reinserts the newlines between them.
    const body =
        "event: token\ndata: hello\n\n" ++
        "event: token\ndata: world\n\n" ++
        "event: done\ndata: {\"completed\":true}\n\n";

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderSse(&w, body);
    try testing.expectEqualStrings("hello\nworld", w.buffered());
}

test "renderSse: preserves leading space in data after the colon" {
    // SSE strips a single optional space after `data:`; anything
    // beyond that is part of the payload.
    const body =
        "event: token\ndata:  indented\n\n" ++
        "event: done\ndata: {}\n\n";

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderSse(&w, body);
    try testing.expectEqualStrings(" indented", w.buffered());
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
