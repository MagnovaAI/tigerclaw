//! `tigerclaw models` — list known models, show the active default,
//! and request a per-session override from the gateway.
//!
//! v0.1.0 scope is deliberately thin:
//!
//!   list           — a table of the models we know about with input /
//!                    output USD-per-million-token pricing. The catalog
//!                    is a fixed slice baked into the binary; future
//!                    commits will hydrate it from config.
//!   status         — prints the canonical default. We don't yet
//!                    persist an override, so this is currently a
//!                    constant; the output documents the v0.2.0 work
//!                    that will make it dynamic.
//!   set <model>    — with `--session <id>`, POST the override to the
//!                    gateway. Without `--session`, the command exits
//!                    1 with a message explaining that persistent
//!                    global default override is v0.2.0 work. Silent
//!                    no-ops in CLI tools are a trap, so we refuse
//!                    rather than appear to succeed.
//!
//! Prices are stored in USD micros (1 USD = 1_000_000 micros) so the
//! catalog avoids float roundtrips and rounding surprises; the display
//! helper renders them as `$15.00` at 2dp.

const std = @import("std");
const http_client = @import("http_client.zig");
const presentation = @import("../presentation.zig");

pub const Subcommand = union(enum) {
    list,
    status,
    set: SetArgs,
};

pub const SetArgs = struct {
    model: []const u8,
    session_id: ?[]const u8 = null,
    base_url: []const u8 = "http://127.0.0.1:8765",
    bearer: ?[]const u8 = null,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
    MissingPositional,
};

/// Per-million-token pricing entry. Prices in USD micros — 15 USD is
/// stored as 15_000_000. Anything over 18 trillion (≈ 18 USD) would
/// overflow u64 but that comfortably clears any plausible future
/// rate; using micros keeps the comparison / formatting integer-only.
pub const ModelInfo = struct {
    name: []const u8,
    provider: []const u8,
    input_per_mtok_usd_micros: u64,
    output_per_mtok_usd_micros: u64,
};

/// Canonical v0.1.0 default. Exposed so `status` and tests share the
/// same source of truth — flipping it here flips it everywhere.
pub const default_model: []const u8 = "anthropic/claude-opus-4-7";

pub const known_models = [_]ModelInfo{
    .{
        .name = "anthropic/claude-opus-4-7",
        .provider = "anthropic",
        .input_per_mtok_usd_micros = 15_000_000,
        .output_per_mtok_usd_micros = 75_000_000,
    },
    .{
        .name = "anthropic/claude-sonnet-4-6",
        .provider = "anthropic",
        .input_per_mtok_usd_micros = 3_000_000,
        .output_per_mtok_usd_micros = 15_000_000,
    },
    .{
        .name = "anthropic/claude-haiku-4-5-20251001",
        .provider = "anthropic",
        .input_per_mtok_usd_micros = 1_000_000,
        .output_per_mtok_usd_micros = 5_000_000,
    },
    .{
        .name = "openai/gpt-4o",
        .provider = "openai",
        .input_per_mtok_usd_micros = 2_500_000,
        .output_per_mtok_usd_micros = 10_000_000,
    },
    .{
        .name = "openai/gpt-4o-mini",
        .provider = "openai",
        .input_per_mtok_usd_micros = 150_000,
        .output_per_mtok_usd_micros = 600_000,
    },
    .{
        .name = "openrouter/auto",
        .provider = "openrouter",
        // Pass-through model selection; pricing depends on the model
        // openrouter routes to. The dashboard is the authoritative
        // source, which the `list` renderer surfaces as a note.
        .input_per_mtok_usd_micros = 0,
        .output_per_mtok_usd_micros = 0,
    },
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    const first = argv[0];
    if (std.mem.eql(u8, first, "list")) {
        if (argv.len > 1) return error.UnknownFlag;
        return .list;
    }
    if (std.mem.eql(u8, first, "status")) {
        if (argv.len > 1) return error.UnknownFlag;
        return .status;
    }
    if (std.mem.eql(u8, first, "set")) return parseSet(argv[1..]);
    return error.UnknownSubcommand;
}

fn parseSet(rest: []const []const u8) ParseError!Subcommand {
    if (rest.len == 0) return error.MissingPositional;
    var args: SetArgs = .{ .model = rest[0] };
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--session")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.session_id = rest[i];
        } else if (std.mem.eql(u8, flag, "--base-url")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.base_url = rest[i];
        } else if (std.mem.eql(u8, flag, "--bearer")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.bearer = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return .{ .set = args };
}

pub const Error = error{
    /// `set <model>` was called without `--session`. v0.1.0 has no
    /// persistent global default; we refuse rather than quietly no-op.
    NoSession,
    /// The gateway returned 404 for the override route — the endpoint
    /// is still v0.2.0 work. Callers surface this as a non-fatal
    /// "not yet implemented" rather than a transport failure.
    GatewayDoesNotSupport,
    UrlTooLong,
    BodyTooLarge,
    NoSpaceLeft,
} || http_client.Error || std.Io.Writer.Error || std.mem.Allocator.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    switch (cmd) {
        .list => try runList(out),
        .status => try runStatus(out),
        .set => |a| try runSet(allocator, io, a, out, err),
    }
}

fn runList(out: *std.Io.Writer) Error!void {
    try out.writeAll("  NAME                                    PROVIDER     INPUT $/Mtok    OUTPUT $/Mtok\n");
    for (&known_models) |m| {
        var in_buf: [16]u8 = undefined;
        var out_buf: [16]u8 = undefined;
        const in_str = try priceCol(&in_buf, m.input_per_mtok_usd_micros);
        const out_str = try priceCol(&out_buf, m.output_per_mtok_usd_micros);
        try out.print("  {s}", .{m.name});
        try padTo(out, m.name.len, 40);
        try out.print("{s}", .{m.provider});
        try padTo(out, m.provider.len, 13);
        try out.print("{s}", .{in_str});
        try padTo(out, in_str.len, 16);
        try out.print("{s}\n", .{out_str});
    }
    try out.writeAll("  note: openrouter/auto prices depend on the underlying route — see https://openrouter.ai\n");
}

fn runStatus(out: *std.Io.Writer) Error!void {
    try out.print("default model: {s}\n", .{default_model});
    try out.writeAll(
        "note: persistent default override is v0.2.0; use `models set` with\n" ++
            "      --session for per-session overrides.\n",
    );
}

fn runSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SetArgs,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    const session = args.session_id orelse {
        try err.writeAll(
            "session-default override requires --session in v0.1.0; persistent\n" ++
                "global default is v0.2.0 work\n",
        );
        return error.NoSession;
    };

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/{s}/model",
        .{ args.base_url, session },
    ) catch return error.UrlTooLong;

    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buf,
        "{{\"model\":\"{s}\"}}",
        .{args.model},
    ) catch return error.BodyTooLarge;

    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    const result = http_client.send(
        allocator,
        io,
        .{
            .method = .POST,
            .url = url,
            .bearer = args.bearer,
            .json_body = body,
        },
        &response_buf.writer,
        .{},
    ) catch |e| switch (e) {
        error.BadRequest => {
            // The route doesn't exist yet — the gateway answers 404,
            // which http_client maps to BadRequest. Disambiguate via
            // the response body when possible; in the common case we
            // treat any 4xx-without-route as the v0.2.0 gap.
            try err.writeAll(
                "gateway does not yet expose /sessions/:id/model — landing in v0.2.0\n",
            );
            return error.GatewayDoesNotSupport;
        },
        else => return e,
    };

    if (result.ok) {
        try out.writeAll("ok\n");
        return;
    }
    try err.print("gateway returned status {d}\n", .{result.status});
    return error.InvalidResponse;
}

/// Format a USD-micros value as `$N.NN` into `buf`. Returns the slice
/// of `buf` actually written. Callers pass a 16-byte buffer which is
/// comfortably larger than `$<20-digit-dollars>.<2-digit-cents>`; the
/// `NoSpaceLeft` case is therefore unreachable with the sizes we use
/// internally but kept on the error set for callers that pass smaller
/// buffers.
pub fn priceCol(buf: []u8, micros: u64) error{NoSpaceLeft}![]const u8 {
    const dollars = micros / 1_000_000;
    const cents = (micros % 1_000_000) / 10_000; // 0..99
    return std.fmt.bufPrint(buf, "${d}.{d:0>2}", .{ dollars, cents });
}

fn padTo(w: *std.Io.Writer, already: usize, target: usize) std.Io.Writer.Error!void {
    if (already >= target) {
        try w.writeByte(' ');
        return;
    }
    var i: usize = 0;
    while (i < target - already) : (i += 1) try w.writeByte(' ');
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: list" {
    const argv = [_][]const u8{"list"};
    try testing.expectEqual(Subcommand.list, try parse(&argv));
}

test "parse: status" {
    const argv = [_][]const u8{"status"};
    try testing.expectEqual(Subcommand.status, try parse(&argv));
}

test "parse: empty argv → MissingSubcommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubcommand, parse(&argv));
}

test "parse: unknown verb → UnknownSubcommand" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

test "parse: set without model → MissingPositional" {
    const argv = [_][]const u8{"set"};
    try testing.expectError(error.MissingPositional, parse(&argv));
}

test "parse: set <model>" {
    const argv = [_][]const u8{ "set", "x" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("x", cmd.set.model);
    try testing.expect(cmd.set.session_id == null);
}

test "parse: set <model> --session s" {
    const argv = [_][]const u8{ "set", "x", "--session", "s" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("x", cmd.set.model);
    try testing.expectEqualStrings("s", cmd.set.session_id.?);
}

test "priceCol: formats $15.00 for 15M micros" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("$15.00", try priceCol(&buf, 15_000_000));
}

test "priceCol: formats $0.15 for 150k micros" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("$0.15", try priceCol(&buf, 150_000));
}

test "run list: mentions the opus default and its price" {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .list, &out, &err);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "anthropic/claude-opus-4-7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "$15.00") != null);
    try testing.expect(std.mem.indexOf(u8, text, "$75.00") != null);
}

test "run status: prints the default + v0.2.0 note" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var err_buf: [64]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try run(testing.allocator, testing.io, .status, &out, &err);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "anthropic/claude-opus-4-7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "v0.2.0") != null);
}

test "run set without --session: returns NoSession with message" {
    var out_buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    try testing.expectError(
        error.NoSession,
        run(testing.allocator, testing.io, .{ .set = .{ .model = "anthropic/claude-opus-4-7" } }, &out, &err),
    );
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "requires --session") != null);
}

// --- fake server plumbing --------------------------------------------------

const FakeServerArgs = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    status: std.http.Status,
    body: []const u8,
};

fn fakeServerThread(args: *FakeServerArgs) void {
    var stream = args.server.accept(args.io) catch return;
    defer stream.close(args.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var s_reader = stream.reader(args.io, &read_buf);
    var s_writer = stream.writer(args.io, &write_buf);

    var http_server = std.http.Server.init(&s_reader.interface, &s_writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond(args.body, .{
        .status = args.status,
        .keep_alive = false,
    }) catch return;
}

test "run set --session with 200 → prints ok" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .ok,
        .body = "{\"ok\":true}",
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var out_buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{ .set = .{
        .model = "anthropic/claude-opus-4-7",
        .session_id = "sess-1",
        .base_url = base,
    } }, &out, &err);
    try testing.expectEqualStrings("ok\n", out.buffered());
}

test "run set --session with 404 → GatewayDoesNotSupport" {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .not_found,
        .body = "{\"error\":\"unknown route\"}",
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var out_buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectError(
        error.GatewayDoesNotSupport,
        run(testing.allocator, testing.io, .{ .set = .{
            .model = "anthropic/claude-opus-4-7",
            .session_id = "sess-1",
            .base_url = base,
        } }, &out, &err),
    );
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "v0.2.0") != null);
}
