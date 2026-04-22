//! `tigerclaw providers` — list known providers and probe each one
//! for reachability + auth.
//!
//! v0.1.0 surface:
//!   list    — table of providers with their build-flag state.
//!   status  — same table, plus a live HTTP probe per enabled
//!             provider. The probe sends a minimal GET to each
//!             provider's documented list/metadata endpoint and
//!             interprets the HTTP status:
//!               2xx / 4xx (non-401) → `ok`   (API recognized us)
//!               401                 → `auth_fail`
//!               connection errors   → `unreachable_`
//!             Anthropic does not publish a GET-friendly endpoint on
//!             /v1/messages, but it returns a well-formed 4xx for
//!             an empty GET — which still proves the host reachable
//!             and the API key shape accepted (or rejected with 401).
//!
//! Keys come from the `--key-<provider>` flags or environment (read
//! at the dispatch site, never inside this module). Base URLs can be
//! overridden via `--base-url-<provider>` so tests can point at a
//! fake `std.http.Server`.

const std = @import("std");

const build_options = @import("build_options");
const presentation = @import("../presentation.zig");

pub const Subcommand = union(enum) {
    list,
    status: StatusArgs,
};

pub const StatusArgs = struct {
    base_url_anthropic: ?[]const u8 = null,
    base_url_openai: ?[]const u8 = null,
    base_url_openrouter: ?[]const u8 = null,
    /// Optional override for env-derived keys. The CLI dispatcher
    /// wires environment variables (`ANTHROPIC_API_KEY`,
    /// `OPENAI_API_KEY`, `OPENROUTER_API_KEY`) into these fields at
    /// the call site; tests populate them directly so the process
    /// environment never leaks into unit tests.
    key_anthropic: ?[]const u8 = null,
    key_openai: ?[]const u8 = null,
    key_openrouter: ?[]const u8 = null,
};

pub const Status = enum {
    ok,
    auth_fail,
    unreachable_,
    no_key,
    disabled,
    skipped,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .auth_fail => "auth fail",
            .unreachable_ => "unreachable",
            .no_key => "no key",
            .disabled => "disabled",
            .skipped => "skipped",
        };
    }
};

pub const ProviderRow = struct {
    name: []const u8,
    enabled: bool,
    status: Status,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownFlag,
    MissingFlagValue,
};

pub fn parse(argv: []const []const u8) ParseError!Subcommand {
    if (argv.len == 0) return error.MissingSubcommand;
    const first = argv[0];
    if (std.mem.eql(u8, first, "list")) {
        if (argv.len > 1) return error.UnknownFlag;
        return .list;
    }
    if (std.mem.eql(u8, first, "status")) return parseStatus(argv[1..]);
    return error.UnknownSubcommand;
}

fn parseStatus(rest: []const []const u8) ParseError!Subcommand {
    var args: StatusArgs = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        const target: *?[]const u8 = if (std.mem.eql(u8, flag, "--base-url-anthropic"))
            &args.base_url_anthropic
        else if (std.mem.eql(u8, flag, "--base-url-openai"))
            &args.base_url_openai
        else if (std.mem.eql(u8, flag, "--base-url-openrouter"))
            &args.base_url_openrouter
        else if (std.mem.eql(u8, flag, "--key-anthropic"))
            &args.key_anthropic
        else if (std.mem.eql(u8, flag, "--key-openai"))
            &args.key_openai
        else if (std.mem.eql(u8, flag, "--key-openrouter"))
            &args.key_openrouter
        else
            return error.UnknownFlag;

        if (i + 1 >= rest.len) return error.MissingFlagValue;
        i += 1;
        target.* = rest[i];
    }
    return .{ .status = args };
}

pub const Error = error{
    UrlTooLong,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    _ = err;
    const rows = try buildRows(allocator, io, cmd);
    defer allocator.free(rows);
    try renderTable(out, rows);
}

fn buildRows(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: Subcommand,
) Error![]ProviderRow {
    return switch (cmd) {
        .list => listRows(allocator),
        .status => |args| probe(allocator, io, args),
    };
}

/// Pure helper for the `list` sub-verb. Returns one row per known
/// provider with `.status = .disabled` for disabled ones and
/// `.status = .ok` for enabled ones — `list` does not probe.
pub fn listRows(allocator: std.mem.Allocator) Error![]ProviderRow {
    const rows = try allocator.alloc(ProviderRow, known_providers.len);
    for (known_providers, 0..) |name, i| {
        const enabled = isEnabled(name);
        rows[i] = .{
            .name = name,
            .enabled = enabled,
            .status = if (enabled) .ok else .disabled,
        };
    }
    return rows;
}

/// Live probe: one HTTP request per enabled provider that has a
/// configured key. Results in an allocator-owned slice the caller
/// must free.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: StatusArgs,
) Error![]ProviderRow {
    const rows = try allocator.alloc(ProviderRow, known_providers.len);
    for (known_providers, 0..) |name, i| {
        rows[i] = .{
            .name = name,
            .enabled = isEnabled(name),
            .status = .disabled,
        };
        if (!rows[i].enabled) continue;

        if (std.mem.eql(u8, name, "mock")) {
            rows[i].status = .ok;
        } else if (std.mem.eql(u8, name, "bedrock")) {
            rows[i].status = .skipped;
        } else if (std.mem.eql(u8, name, "anthropic")) {
            rows[i].status = try probeAnthropic(allocator, io, args);
        } else if (std.mem.eql(u8, name, "openai")) {
            rows[i].status = try probeOpenAI(allocator, io, args);
        } else if (std.mem.eql(u8, name, "openrouter")) {
            rows[i].status = try probeOpenRouter(allocator, io, args);
        } else unreachable;
    }
    return rows;
}

const known_providers = [_][]const u8{
    "mock",
    "anthropic",
    "openai",
    "openrouter",
    "bedrock",
};

fn isEnabled(name: []const u8) bool {
    if (std.mem.eql(u8, name, "mock")) return true;
    if (std.mem.eql(u8, name, "anthropic")) return build_options.enable_anthropic;
    if (std.mem.eql(u8, name, "openai")) return build_options.enable_openai;
    if (std.mem.eql(u8, name, "openrouter")) return build_options.enable_openrouter;
    if (std.mem.eql(u8, name, "bedrock")) return build_options.enable_bedrock;
    unreachable;
}

fn probeAnthropic(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: StatusArgs,
) Error!Status {
    const key = args.key_anthropic orelse return .no_key;
    const base = args.base_url_anthropic orelse "https://api.anthropic.com";

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{base}) catch
        return error.UrlTooLong;

    const headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    return httpProbe(allocator, io, url, &headers);
}

fn probeOpenAI(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: StatusArgs,
) Error!Status {
    const key = args.key_openai orelse return .no_key;
    const base = args.base_url_openai orelse "https://api.openai.com";

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/v1/models", .{base}) catch
        return error.UrlTooLong;

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch
        return error.UrlTooLong;

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth },
    };
    return httpProbe(allocator, io, url, &headers);
}

fn probeOpenRouter(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: StatusArgs,
) Error!Status {
    const key = args.key_openrouter orelse return .no_key;
    const base = args.base_url_openrouter orelse "https://openrouter.ai";

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/models", .{base}) catch
        return error.UrlTooLong;

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch
        return error.UrlTooLong;

    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth },
    };
    return httpProbe(allocator, io, url, &headers);
}

/// Issue a one-shot GET and classify the outcome into a `Status`.
/// Any non-memory error maps to `.unreachable_` — the probe is
/// advisory, so we never surface transport-level details further
/// up. 401 is the only "interesting" auth code: 2xx and other 4xx
/// responses are taken as proof the host is reachable and at least
/// accepted the request framing.
fn httpProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
) Error!Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .extra_headers = extra_headers,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unreachable_,
    };

    const code: u16 = @intFromEnum(result.status);
    if (code == 401) return .auth_fail;
    if (code >= 200 and code < 500) return .ok;
    return .unreachable_;
}

fn renderTable(out: *std.Io.Writer, rows: []const ProviderRow) std.Io.Writer.Error!void {
    try out.writeAll("NAME         ENABLED  STATUS\n");
    for (rows) |row| {
        try out.print("{s}", .{row.name});
        try writePadding(out, row.name.len, 13);
        const enabled_label: []const u8 = if (row.enabled) "yes" else "no";
        try out.writeAll(enabled_label);
        try writePadding(out, enabled_label.len, 9);
        try out.print("{s}\n", .{row.status.label()});
    }
}

fn writePadding(out: *std.Io.Writer, written: usize, target: usize) std.Io.Writer.Error!void {
    if (written >= target) {
        try out.writeByte(' ');
        return;
    }
    var i = written;
    while (i < target) : (i += 1) try out.writeByte(' ');
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: list" {
    const argv = [_][]const u8{"list"};
    const cmd = try parse(&argv);
    try testing.expect(cmd == .list);
}

test "parse: status with no flags yields defaults" {
    const argv = [_][]const u8{"status"};
    const cmd = try parse(&argv);
    try testing.expect(cmd == .status);
    try testing.expect(cmd.status.key_openai == null);
    try testing.expect(cmd.status.base_url_openai == null);
}

test "parse: missing subcommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubcommand, parse(&argv));
}

test "parse: unknown subcommand" {
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownSubcommand, parse(&argv));
}

test "parse: status --key-openai captures the value" {
    const argv = [_][]const u8{ "status", "--key-openai", "sk-test" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("sk-test", cmd.status.key_openai.?);
}

test "parse: status --unknown flag returns UnknownFlag" {
    const argv = [_][]const u8{ "status", "--unknown" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: status --key-openai without value returns MissingFlagValue" {
    const argv = [_][]const u8{ "status", "--key-openai" };
    try testing.expectError(error.MissingFlagValue, parse(&argv));
}

test "probe: no keys → no_key for network providers, ok for mock, skipped for bedrock" {
    const rows = try probe(testing.allocator, testing.io, .{});
    defer testing.allocator.free(rows);

    for (rows) |row| {
        if (std.mem.eql(u8, row.name, "mock")) {
            try testing.expectEqual(Status.ok, row.status);
        } else if (std.mem.eql(u8, row.name, "bedrock")) {
            if (row.enabled) {
                try testing.expectEqual(Status.skipped, row.status);
            } else {
                try testing.expectEqual(Status.disabled, row.status);
            }
        } else if (row.enabled) {
            try testing.expectEqual(Status.no_key, row.status);
        } else {
            try testing.expectEqual(Status.disabled, row.status);
        }
    }
}

// --- fake http server for probe tests --------------------------------------

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

test "probe: fake openai returning 200 → ok" {
    if (!build_options.enable_openai) return error.SkipZigTest;

    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var fake_args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .ok,
        .body = "{\"data\":[]}",
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&fake_args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    const rows = try probe(testing.allocator, testing.io, .{
        .base_url_openai = base,
        .key_openai = "sk-test",
    });
    defer testing.allocator.free(rows);

    const row = findRow(rows, "openai").?;
    try testing.expectEqual(Status.ok, row.status);
}

test "probe: fake openai returning 401 → auth_fail" {
    if (!build_options.enable_openai) return error.SkipZigTest;

    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();

    var fake_args: FakeServerArgs = .{
        .io = testing.io,
        .server = &server,
        .status = .unauthorized,
        .body = "{\"error\":\"bad key\"}",
    };
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{&fake_args});
    defer thread.join();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    const rows = try probe(testing.allocator, testing.io, .{
        .base_url_openai = base,
        .key_openai = "sk-test",
    });
    defer testing.allocator.free(rows);

    const row = findRow(rows, "openai").?;
    try testing.expectEqual(Status.auth_fail, row.status);
}

fn findRow(rows: []const ProviderRow, name: []const u8) ?ProviderRow {
    for (rows) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

test "renderTable: header and one row per provider" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const rows = [_]ProviderRow{
        .{ .name = "mock", .enabled = true, .status = .ok },
        .{ .name = "bedrock", .enabled = false, .status = .disabled },
    };
    try renderTable(&w, &rows);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "NAME") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ENABLED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "STATUS") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mock") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bedrock") != null);
    try testing.expect(std.mem.indexOf(u8, out, "disabled") != null);
}
