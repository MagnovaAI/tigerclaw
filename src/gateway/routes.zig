//! Canonical route table + handler set for the gateway HTTP surface.
//!
//! The gateway exposes a small RESTy API that the CLI client and the
//! Telegram dispatch layer both consume. Endpoints land in two
//! slices: `routes` (the pattern table fed to the router) and
//! `handlers` (the tag→fn map fed to the dispatcher).
//!
//! Handlers live here as thin adapters that translate the matched
//! request into an `AgentRunner` call. The runner implementation is
//! injected via a per-process `Context` — tests use the mock runner,
//! the real daemon will wire the react-loop runner.

const std = @import("std");
const router = @import("router.zig");
const http = @import("http.zig");
const dispatcher = @import("dispatcher.zig");
const harness = @import("../harness/root.zig");
const settings = @import("../settings/root.zig");
const db_mod = @import("../db/root.zig");
const clock_mod = @import("clock");
const instance_auth = @import("../instances/auth.zig");

pub const Context = struct {
    runner: harness.AgentRunner,
    /// Optional runtime registry. When set, `/health` reports the
    /// runner count and the sum of in-flight turns across every
    /// runner — useful for ops watching drain across a multi-agent
    /// daemon. The single-runner `runner` field above stays the
    /// default route target so handlers that don't care about
    /// multi-agent routing keep working.
    runtime: ?*harness.Runtime = null,
    /// Optional per-session budget consulted before each turn. When
    /// populated, the turn handler rejects requests with 429 as soon
    /// as any axis (turns / input_tokens / output_tokens / cost_micros)
    /// hits its cap. Left null in tests that exercise the routing
    /// surface without caring about budget policy.
    budget: ?*harness.Budget = null,
    /// Invoked synchronously from `/config/reload` before the
    /// generation counter is bumped. The boot layer wires this to its
    /// own rebuild hook; tests install a counter. Null in routing
    /// tests that don't care about the reload side-effect.
    reload_callback: ?*const fn (userdata: ?*anyopaque) void = null,
    reload_userdata: ?*anyopaque = null,
    /// SQLite handle backing the instance registry. When null, the
    /// `/instances/*` routes return 503 — the daemon was constructed
    /// without persistence (legacy paths, some test configurations).
    /// The pointer is stable for the lifetime of the gateway.
    db: ?*db_mod.Db = null,
    /// Clock used by `/instances/*` handlers to stamp registration
    /// and heartbeat timestamps. Tests install a `FixedClock` so the
    /// recorded `connected_at_ns` and `last_heartbeat_at_ns` columns
    /// are deterministic across runs. When `db` is set, this must
    /// also be set; the route layer ANDs them at the entry point.
    clock: ?clock_mod.Clock = null,
    /// Io handle used to source secure entropy for the registration
    /// route's token generator. Threaded through the same way `db`
    /// and `clock` are: production wires the gateway's threaded Io,
    /// tests wire `std.testing.io`.
    io: ?std.Io = null,
};

/// Immutable bundle of the settings the runtime was started with plus
/// the reload generation at the moment the bundle was published. A
/// request handler reads the pointer once at entry, which gives it a
/// stable view for the duration of the call — mid-request reloads
/// cannot perturb an in-flight turn's config.
pub const SettingsSnapshot = struct {
    settings: settings.Settings,
    generation: u64,
};

/// Atomically swappable pointer to the current snapshot. The boot
/// layer populates this at startup and each `/config/reload`. Pointer
/// load and store are atomic on the targets we ship for (aarch64 /
/// x86_64); the pointed-at snapshot is immutable, so once a handler
/// has the pointer it has a stable view.
pub var active_snapshot: std.atomic.Value(?*const SettingsSnapshot) = .init(null);

pub fn setActiveSnapshot(snap: *const SettingsSnapshot) void {
    active_snapshot.store(snap, .release);
}

pub fn clearActiveSnapshot() void {
    active_snapshot.store(null, .release);
}

pub fn activeSnapshot() ?*const SettingsSnapshot {
    return active_snapshot.load(.acquire);
}

/// Thread-local handler context. Zig does not expose a clean way to
/// attach per-request state onto a function-pointer-shaped handler
/// without widening the `dispatcher.Handler` signature, so we let the
/// handler reach into a caller-managed context pointer. The gateway
/// daemon sets this once at boot and never mutates it afterwards.
var active_context: ?*Context = null;

pub fn setContext(ctx: *Context) void {
    active_context = ctx;
}

pub fn clearContext() void {
    active_context = null;
}

fn contextOrInternal() dispatcher.HandlerError!*Context {
    return active_context orelse error.InternalServerError;
}

// --- route table -----------------------------------------------------------

/// Monotonic counter bumped every time `POST /config/reload` is
/// accepted. External watchers (and a future in-process hot-reload)
/// poll this to detect that a reload has been requested. The counter
/// is process-wide because the route handler is stateless; the boot
/// layer is the single writer of meaning here — it observes the
/// change and decides what to do.
pub var reload_generation: std.atomic.Value(u64) = .init(0);

pub const routes = [_]router.Route{
    .{ .method = .GET, .pattern = "/health", .tag = "health" },
    .{ .method = .POST, .pattern = "/config/reload", .tag = "config.reload" },
    .{ .method = .GET, .pattern = "/sessions", .tag = "sessions.list" },
    .{ .method = .POST, .pattern = "/sessions", .tag = "sessions.create" },
    .{ .method = .GET, .pattern = "/sessions/:id", .tag = "sessions.get" },
    .{ .method = .DELETE, .pattern = "/sessions/:id", .tag = "sessions.delete" },
    .{ .method = .POST, .pattern = "/sessions/:id/messages", .tag = "sessions.message" },
    .{ .method = .POST, .pattern = "/sessions/:id/turns", .tag = "sessions.turn" },
    .{ .method = .DELETE, .pattern = "/sessions/:id/turns/current", .tag = "sessions.turn.cancel" },
    .{ .method = .POST, .pattern = "/instances/register", .tag = "instances.register" },
    .{ .method = .POST, .pattern = "/instances/:id/heartbeat", .tag = "instances.heartbeat" },
    .{ .method = .DELETE, .pattern = "/instances/:id", .tag = "instances.delete" },
};

pub const handlers = [_]dispatcher.HandlerEntry{
    .{ .tag = "health", .handler = healthHandler },
    .{ .tag = "config.reload", .handler = configReloadHandler },
    .{ .tag = "sessions.list", .handler = sessionsListHandler },
    .{ .tag = "sessions.create", .handler = sessionsCreateHandler },
    .{ .tag = "sessions.get", .handler = sessionsGetHandler },
    .{ .tag = "sessions.delete", .handler = sessionsDeleteHandler },
    .{ .tag = "sessions.message", .handler = sessionsMessageHandler },
    .{ .tag = "sessions.turn", .handler = sessionsTurnHandler },
    .{ .tag = "sessions.turn.cancel", .handler = sessionsTurnCancelHandler },
    .{ .tag = "instances.register", .handler = instancesRegisterHandler },
    .{ .tag = "instances.heartbeat", .handler = instancesHeartbeatHandler },
    .{ .tag = "instances.delete", .handler = instancesDeleteHandler },
};

// --- handlers --------------------------------------------------------------

fn healthHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    // When a Runtime is wired, surface the runner count and the sum
    // of in-flight turns so ops can script drain progress against
    // /health. Without a Runtime we keep the legacy minimal body so
    // existing clients keep parsing.
    if (ctx.runtime) |rt| {
        var w = std.Io.Writer.fixed(&render_body_buf);
        w.print(
            "{{\"status\":\"ok\",\"runners\":{d},\"in_flight\":{d}}}",
            .{ rt.count(), rt.totalInFlight() },
        ) catch return error.InternalServerError;
        return http.Response.jsonOk(w.buffered());
    }
    return http.Response.jsonOk("{\"status\":\"ok\"}");
}

/// POST /config/reload — surface the wire shape for a hot-reload
/// signal. This is a stub in v0.1.0: it bumps `reload_generation` and
/// returns 202 so callers can confirm the request was accepted, but
/// the process does not actually re-read settings or rebuild the
/// channel manager yet. Wiring that up is a follow-up commit; here we
/// pin the public surface so operators can script against it now.
fn configReloadHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    if (ctx.reload_callback) |cb| cb(ctx.reload_userdata);
    _ = reload_generation.fetchAdd(1, .monotonic);
    return .{
        .status = .accepted,
        .headers = &json_headers,
        .body = "{\"reload\":\"queued\"}",
    };
}

fn sessionsListHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    // The mock gateway does not persist sessions; return an empty
    // array so clients can smoke-test the shape.
    return http.Response.jsonOk("{\"sessions\":[]}");
}

fn sessionsCreateHandler(
    _: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    // Always returns a fixed mock id so tests are deterministic.
    return .{
        .status = .created,
        .headers = &json_headers,
        .body = "{\"id\":\"mock-session\"}",
    };
}

fn sessionsGetHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const id = findParam(params, "id") orelse return error.BadRequest;
    if (std.mem.eql(u8, id, "mock-session")) {
        return http.Response.jsonOk("{\"id\":\"mock-session\",\"turns\":0}");
    }
    return http.Response.notFound();
}

fn sessionsDeleteHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .no_content };
}

fn sessionsMessageHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    _ = findParam(params, "id") orelse return error.BadRequest;
    return .{ .status = .accepted };
}

fn sessionsTurnHandler(
    req: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    stream_hook: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const id = findParam(params, "id") orelse return error.BadRequest;

    // Budget gate — see the non-streaming note below, same semantics.
    if (ctx.budget) |b| {
        if (b.check() != .none) return .{
            .status = .too_many_requests,
            .headers = &json_headers,
            .body = "{\"error\":\"budget_exceeded\"}",
        };
    }

    const message_or_empty = extractMessage(req.body) catch return error.BadRequest;
    const message = if (message_or_empty.len > 0) message_or_empty else "ping";

    // Non-streaming path (e.g. the CLI smoke tests that don't ask for
    // SSE) still goes through the blocking run + JSON envelope. The
    // streaming branch below lives alongside so regressions to the
    // old path remain trivially bisectable.
    if (!wantsSse(req) or stream_hook == null) {
        const result = ctx.runner.run(.{ .session_id = id, .input = message }) catch |err| switch (err) {
            error.SessionMissing => return http.Response.notFound(),
            error.BudgetExceeded => return .{ .status = .too_many_requests, .body = "budget exceeded\n" },
            else => return error.InternalServerError,
        };
        return renderJsonFromOutput(result.output);
    }

    return streamTurn(ctx, stream_hook.?, id, message);
}

/// Stream the turn over a chunked `text/event-stream` response.
///
/// Emits v1-compatible JSON-envelope frames:
/// * `data: {"type":"chunk","text":"..."}\n\n` per provider text delta
/// * `data: {"type":"tool_start","id":"...","name":"..."}\n\n` per dispatch
/// * `data: {"type":"tool_done","id":"...","name":"...","output":"..."}\n\n`
/// * `data: {"type":"done"}\n\n` terminal frame
/// * `data: {"type":"error","message":"..."}\n\n` on failure (followed by done)
///
/// Each frame is flushed immediately so the client sees it before the
/// turn completes. Returns `Response.streamingHandled()` so the
/// tcp_server does not try to write a second response envelope.
fn streamTurn(
    ctx: *Context,
    stream_hook: dispatcher.StreamHook,
    session_id: []const u8,
    message: []const u8,
) dispatcher.HandlerError!http.Response {
    const request: *std.http.Server.Request = @ptrCast(@alignCast(stream_hook.?));

    var send_buf: [1024]u8 = undefined;
    var body_writer = request.respondStreaming(&send_buf, .{
        .respond_options = .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    }) catch return error.InternalServerError;

    var frame_ctx: StreamCtx = .{ .body = &body_writer };

    // Fire the turn through the runner with both sinks wired. The
    // runner invokes these synchronously from the dispatch thread;
    // this handler is single-threaded-per-request so no locking is
    // needed around the body writer.
    const run_err = ctx.runner.run(.{
        .session_id = session_id,
        .input = message,
        .stream_sink = chunkSink,
        .stream_sink_ctx = &frame_ctx,
        .tool_event_sink = toolEventSink,
        .tool_event_sink_ctx = &frame_ctx,
    });

    if (run_err) |_| {
        writeFrame(&body_writer, "{\"type\":\"done\"}") catch {};
    } else |err| {
        const msg = switch (err) {
            error.SessionMissing => "session missing",
            error.BudgetExceeded => "budget exceeded",
            error.Cancelled, error.Interrupted => "turn cancelled",
            else => "internal error",
        };
        writeErrorFrame(&body_writer, msg) catch {};
        writeFrame(&body_writer, "{\"type\":\"done\"}") catch {};
    }

    body_writer.end() catch {};
    return http.Response.streamingHandled();
}

/// Context both sinks share. Single field today; kept as a struct so
/// later additions (cancel token, frame counter) don't ripple through
/// every sink signature.
const StreamCtx = struct {
    body: *std.http.BodyWriter,
};

fn chunkSink(ctx: ?*anyopaque, fragment: []const u8) void {
    const self: *StreamCtx = @ptrCast(@alignCast(ctx.?));
    writeChunkFrame(self.body, fragment) catch {};
}

fn toolEventSink(
    ctx: ?*anyopaque,
    event: harness.agent_runner.ToolEvent,
) void {
    const self: *StreamCtx = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .started => |s| writeToolStartFrame(self.body, s.id, s.name) catch {},
        // SSE consumers don't yet ingest progress chunks -- the
        // streaming format (text/event-stream) framing for partial
        // tool output is a separate design conversation. Drop for
        // now; the final tool_result lands on `.finished`.
        .progress => {},
        .finished => |f| writeToolDoneFrame(self.body, f.id, f.name, f.kind.flatText()) catch {},
    }
}

/// Write a `data: <json>\n\n` frame and flush so the bytes hit the
/// socket before the next frame is built.
fn writeFrame(body: *std.http.BodyWriter, json_line: []const u8) !void {
    try body.writer.writeAll("data: ");
    try body.writer.writeAll(json_line);
    try body.writer.writeAll("\n\n");
    try body.writer.flush();
}

fn writeChunkFrame(body: *std.http.BodyWriter, text: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"chunk\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeToolStartFrame(body: *std.http.BodyWriter, id: []const u8, name: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"tool_start\",\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, &body.writer);
    try body.writer.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeToolDoneFrame(
    body: *std.http.BodyWriter,
    id: []const u8,
    name: []const u8,
    output: []const u8,
) !void {
    try body.writer.writeAll("data: {\"type\":\"tool_done\",\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, &body.writer);
    try body.writer.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    try body.writer.writeAll(",\"output\":");
    try std.json.Stringify.encodeJsonString(output, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

fn writeErrorFrame(body: *std.http.BodyWriter, message: []const u8) !void {
    try body.writer.writeAll("data: {\"type\":\"error\",\"message\":");
    try std.json.Stringify.encodeJsonString(message, .{}, &body.writer);
    try body.writer.writeAll("}\n\n");
    try body.writer.flush();
}

/// Pull `message` out of the request body JSON. Empty body → empty
/// string (the runner falls back to a deterministic prompt). Returns
/// `error.BadRequest` for malformed JSON or non-string `message` to
/// surface a typo at the wire boundary instead of inside the runner.
fn extractMessage(body: []const u8) error{BadRequest}![]const u8 {
    if (body.len == 0) return "";
    // We need a leaky parse so we can borrow the slice into the body
    // bytes without re-allocating. The handler returns immediately
    // after this; the tcp_server frees `body` once dispatch finishes.
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch
        return error.BadRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadRequest;
    const m = parsed.value.object.get("message") orelse return "";
    if (m != .string) return error.BadRequest;
    // Slice aliases the parsed arena; that arena dies at deinit above.
    // We re-find the slice in the original body so the returned slice
    // outlives this function.
    const needle = m.string;
    const start = std.mem.indexOf(u8, body, needle) orelse return error.BadRequest;
    return body[start .. start + needle.len];
}

/// Shared buffer for both the SSE and JSON renderers. Threadlocal
/// so two concurrent requests on different TCP-server threads don't
/// stomp each other; each handler consumes its own thread's buffer
/// before the thread services the next request.
threadlocal var render_body_buf: [16 * 1024]u8 = undefined;

/// Build a plain JSON response carrying the runner's output. The
/// TUI / CLI clients consume this without having to parse SSE; the
/// `output` field is a JSON-escaped string, so newlines and quotes
/// round-trip cleanly.
fn renderJsonFromOutput(output: []const u8) http.Response {
    // JSON-escape `output` into the thread-local buffer. We leave
    // 64 bytes of headroom for the surrounding {"output":""} shell.
    const budget = render_body_buf.len - 64;
    const src = if (output.len > budget) output[0..budget] else output;

    var w = std.Io.Writer.fixed(&render_body_buf);
    w.writeAll("{\"output\":") catch return .{ .status = .internal_server_error, .body = "render failed\n" };
    std.json.Stringify.encodeJsonString(src, .{}, &w) catch
        return .{ .status = .internal_server_error, .body = "render failed\n" };
    w.writeAll("}") catch return .{ .status = .internal_server_error, .body = "render failed\n" };
    return http.Response.jsonOk(w.buffered());
}

// --- /instances/* ---------------------------------------------------------

/// POST /instances/register — record a new client (TUI/CLI/web) in
/// the instances table and return its bearer token. The token is
/// shown to the client exactly once; the gateway only ever stores
/// its Blake3 hash. Body shape:
///     {"kind":"tui","name":"alice","agent_id":"tiger",
///      "session_id":"...","heartbeat_interval_ms":30000}
/// Only `kind` is required. Returns 201 with `{id, token}` or 503
/// when the gateway was started without a database (legacy mode).
fn instancesRegisterHandler(
    req: http.Request,
    _: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const db = ctx.db orelse return dbUnavailable();
    const clock = ctx.clock orelse return dbUnavailable();
    const io = ctx.io orelse return dbUnavailable();

    const args = parseRegisterBody(req.body) catch return error.BadRequest;

    var id_buf: [16]u8 = undefined;
    const id = instance_auth.genInstanceId(io, &id_buf, args.kind.toString()) catch
        return error.InternalServerError;
    const token = instance_auth.generate(io) catch return error.InternalServerError;
    const token_hash = instance_auth.hash(&token);

    const now = clock.nowNs();
    var repo = db_mod.InstanceRepo.init(db);
    repo.insert(.{
        .id = id,
        .kind = args.kind,
        .name = args.name,
        .agent_id = args.agent_id,
        .session_id = args.session_id,
        .heartbeat_interval_ms = args.heartbeat_interval_ms,
        .connected_at_ns = now,
        .last_heartbeat_at_ns = now,
    }) catch return error.InternalServerError;
    _ = repo.setTokenHash(id, &token_hash) catch return error.InternalServerError;

    var w = std.Io.Writer.fixed(&render_body_buf);
    w.writeAll("{\"id\":\"") catch return error.InternalServerError;
    w.writeAll(id) catch return error.InternalServerError;
    w.writeAll("\",\"token\":\"") catch return error.InternalServerError;
    w.writeAll(&token) catch return error.InternalServerError;
    w.writeAll("\"}") catch return error.InternalServerError;

    return .{
        .status = .created,
        .headers = &json_headers,
        .body = w.buffered(),
    };
}

/// POST /instances/:id/heartbeat — bump `last_heartbeat_at_ns` and
/// clear any soft eviction. Returns 204 on success or 404 when the
/// id is unknown (the TUI re-registers on 404; that contract is
/// load-bearing for the sweeper's "soft eviction can be revived"
/// semantics). When the row carries a token hash, the request must
/// present a matching `Authorization: Bearer <token>` header.
fn instancesHeartbeatHandler(
    req: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const db = ctx.db orelse return dbUnavailable();
    const clock = ctx.clock orelse return dbUnavailable();

    const id = findParam(params, "id") orelse return error.BadRequest;

    var repo = db_mod.InstanceRepo.init(db);
    switch (try resolveInstanceAuth(&repo, req, id)) {
        .ok => {},
        .response => |r| return r,
    }
    const ok = repo.heartbeat(id, clock.nowNs()) catch return error.InternalServerError;
    if (!ok) return http.Response.notFound();
    return .{ .status = .no_content };
}

/// DELETE /instances/:id — graceful shutdown signal from the client.
/// Hard-deletes the row so the slot is reusable immediately rather
/// than waiting for the eviction sweeper. Idempotent: 204 either
/// way; we don't surface "already gone" because the client's intent
/// is "be gone", and the row is. Auth-protected the same way as
/// heartbeat.
fn instancesDeleteHandler(
    req: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    const db = ctx.db orelse return dbUnavailable();
    const id = findParam(params, "id") orelse return error.BadRequest;

    var repo = db_mod.InstanceRepo.init(db);
    switch (try resolveInstanceAuth(&repo, req, id)) {
        .ok => {},
        .response => |r| return r,
    }
    repo.delete(id) catch return error.InternalServerError;
    return .{ .status = .no_content };
}

const AuthDecision = union(enum) {
    /// The request is authorized to act on this instance row.
    ok,
    /// Short-circuit response: 401 (token mismatch / missing) or
    /// 404 (the row does not exist; we surface the same 404 here
    /// that the underlying op would emit, so the client doesn't
    /// have to distinguish "auth failed" from "row gone").
    response: http.Response,
};

/// Look up the row, then run the bearer check against its stored
/// hash. Returns `.ok` for matched-or-open access, otherwise the
/// 401/404 response the handler should return verbatim.
fn resolveInstanceAuth(
    repo: *db_mod.InstanceRepo,
    req: http.Request,
    id: []const u8,
) dispatcher.HandlerError!AuthDecision {
    const stored = repo.tokenHashFor(std.heap.page_allocator, id) catch
        return error.InternalServerError;
    const stored_hash = stored orelse return .{ .response = http.Response.notFound() };
    defer std.heap.page_allocator.free(stored_hash);

    const auth_header = req.getHeader("authorization");
    return switch (instance_auth.checkBearer(auth_header, stored_hash)) {
        .open, .match => .ok,
        .mismatch, .missing => .{ .response = unauthorized() },
    };
}

fn unauthorized() http.Response {
    return .{
        .status = .unauthorized,
        .headers = &unauthorized_headers,
        .body = "{\"error\":\"unauthorized\"}",
    };
}

const unauthorized_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "www-authenticate", .value = "Bearer" },
};

const RegisterBody = struct {
    kind: db_mod.InstanceKind,
    name: []const u8 = "",
    agent_id: []const u8 = "",
    session_id: []const u8 = "",
    heartbeat_interval_ms: u32 = 0,
};

/// Parse the registration body. The slices in the returned struct
/// alias the original `body` bytes — `parseFromSlice` would build a
/// short-lived arena, so we pull each field out by re-finding it in
/// `body`, the same trick `extractMessage` uses above. Caller frees
/// `body` after the handler returns.
fn parseRegisterBody(body: []const u8) !RegisterBody {
    if (body.len == 0) return error.BadRequest;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadRequest;
    const obj = parsed.value.object;

    const kind_v = obj.get("kind") orelse return error.BadRequest;
    if (kind_v != .string) return error.BadRequest;
    const kind = db_mod.InstanceKind.fromString(kind_v.string) orelse return error.BadRequest;

    var out: RegisterBody = .{ .kind = kind };
    out.name = sliceField(body, obj.get("name")) orelse "";
    out.agent_id = sliceField(body, obj.get("agent_id")) orelse "";
    out.session_id = sliceField(body, obj.get("session_id")) orelse "";

    if (obj.get("heartbeat_interval_ms")) |hb| {
        if (hb == .integer and hb.integer >= 0 and hb.integer <= std.math.maxInt(u32)) {
            out.heartbeat_interval_ms = @intCast(hb.integer);
        } else return error.BadRequest;
    }
    return out;
}

/// Re-anchor a parsed JSON string into the original request body so
/// the slice outlives the local parse arena. Returns null when the
/// JSON value is missing or not a string.
fn sliceField(body: []const u8, value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    if (v != .string) return null;
    const needle = v.string;
    if (needle.len == 0) return "";
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    return body[start .. start + needle.len];
}

fn dbUnavailable() http.Response {
    return .{
        .status = .service_unavailable,
        .headers = &json_headers,
        .body = "{\"error\":\"db_unavailable\"}",
    };
}

/// DELETE /sessions/:id/turns/current — cancel the in-flight turn for
/// `id`. Idempotent: returns 204 even when no turn is in flight, so the
/// CLI's Ctrl-C handler can fire without having to track turn state.
fn sessionsTurnCancelHandler(
    _: http.Request,
    params: []const router.Param,
    _: ?[]const u8,
    _: dispatcher.StreamHook,
) dispatcher.HandlerError!http.Response {
    const ctx = try contextOrInternal();
    _ = findParam(params, "id") orelse return error.BadRequest;

    // The mock runner ignores the turn id; production will plumb a
    // session→turn map so cancel reaches the right react loop. The
    // value zero is a sentinel for "current turn on this session".
    ctx.runner.cancel(0);
    return .{ .status = .no_content };
}

fn wantsSse(req: http.Request) bool {
    const accept = req.getHeader("accept") orelse return false;
    return std.mem.indexOf(u8, accept, "text/event-stream") != null;
}

fn findParam(params: []const router.Param, name: []const u8) ?[]const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

const json_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn withMockContext(comptime body: fn (runner: *harness.MockAgentRunner) anyerror!void) !void {
    var mock = harness.MockAgentRunner.init();
    var ctx: Context = .{ .runner = mock.runner() };
    setContext(&ctx);
    defer clearContext();
    try body(&mock);
}

fn runHealth(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/health", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

test "routes: GET /health returns 200" {
    try withMockContext(runHealth);
}

/// Provider stub for /health probe — only `kind` is read by the
/// Manager; everything else is unused on this path.
const HealthStubProvider = struct {
    fn provider(self: *HealthStubProvider) memory_test_mod.Provider {
        return .{ .ptr = self, .vtable = &vt, .kind = .builtin, .name = "stub" };
    }
    fn initFn(_: *anyopaque) memory_test_mod.MemoryError!void {}
    fn sysFn(_: *anyopaque) memory_test_mod.MemoryError![]const u8 {
        return "";
    }
    fn prefetchFn(_: *anyopaque, _: []const u8) memory_test_mod.MemoryError!memory_test_mod.provider.Prefetch {
        return .{ .text = "" };
    }
    fn syncFn(_: *anyopaque, _: memory_test_mod.provider.TurnPair) memory_test_mod.MemoryError!void {}
    fn shutdownFn(_: *anyopaque) void {}
    const vt: memory_test_mod.provider.VTable = .{
        .initialize = initFn,
        .system_prompt_block = sysFn,
        .prefetch = prefetchFn,
        .sync_turn = syncFn,
        .shutdown = shutdownFn,
    };
};

test "routes: GET /health surfaces runner count and in-flight when a Runtime is wired" {
    var mock = harness.MockAgentRunner.init();

    var stub: HealthStubProvider = .{};
    var mgr = memory_test_mod.Manager.init(testing.allocator, stub.provider());
    defer mgr.deinit();

    var rt = harness.Runtime.init(testing.allocator, &mgr, "");
    defer rt.deinit();

    var ctx: Context = .{ .runner = mock.runner(), .runtime = &rt };
    setContext(&ctx);
    defer clearContext();

    const req: http.Request = .{ .method = .GET, .target = "/health", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"runners\":0") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"in_flight\":0") != null);
}

const memory_test_mod = @import("../memory/root.zig");

fn runList(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expectEqualStrings("{\"sessions\":[]}", resp.body);
}

test "routes: GET /sessions returns an empty list in mock mode" {
    try withMockContext(runList);
}

fn runCreate(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.created, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "mock-session") != null);
}

test "routes: POST /sessions returns 201 with the canned id" {
    try withMockContext(runCreate);
}

fn runGet(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/mock-session", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
}

test "routes: GET /sessions/mock-session returns 200" {
    try withMockContext(runGet);
}

fn runGetMissing(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .GET, .target = "/sessions/unknown", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.not_found, resp.status);
}

test "routes: GET /sessions/unknown returns 404" {
    try withMockContext(runGetMissing);
}

fn runTurn(runner: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .POST, .target = "/sessions/s1/turns", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(runner.in_flight.isZero());
}

test "routes: POST /sessions/:id/turns round-trips the in-flight counter" {
    try withMockContext(runTurn);
}

test "routes: POST /sessions/:id/turns returns 429 when the budget is exhausted" {
    var mock = harness.MockAgentRunner.init();
    var budget = harness.Budget.init(.{ .turns = 1 });
    budget.recordTurn(0, 0, 0);

    var ctx: Context = .{ .runner = mock.runner(), .budget = &budget };
    setContext(&ctx);
    defer clearContext();

    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.too_many_requests, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "budget_exceeded") != null);

    // The runner must NOT have been called — in-flight stays at zero.
    try testing.expect(mock.in_flight.isZero());
}

fn runTurnSseFallback(runner: *harness.MockAgentRunner) anyerror!void {
    // In-process dispatch has no real `std.http.Server.Request` to
    // stream through, so the handler falls back to the buffered JSON
    // path even when Accept requests SSE. The live streaming path is
    // covered by the e2e gateway test.
    const accept = [_]http.Header{.{ .name = "accept", .value = "text/event-stream" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/sessions/s1/turns",
        .headers = &accept,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.ok, resp.status);
    try testing.expect(runner.in_flight.isZero());
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"output\"") != null);
}

test "routes: POST /sessions/:id/turns falls back to JSON when no stream hook present" {
    try withMockContext(runTurnSseFallback);
}

fn runTurnCancel(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{
        .method = .DELETE,
        .target = "/sessions/s1/turns/current",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id/turns/current returns 204 (idempotent)" {
    try withMockContext(runTurnCancel);
}

fn runTurnCancelMissingId(_: *harness.MockAgentRunner) anyerror!void {
    // Without a path param the dispatcher routes to a different
    // pattern and we never reach the handler — verify the explicit
    // 204 path requires the :id segment to be present.
    const req: http.Request = .{
        .method = .DELETE,
        .target = "/sessions//turns/current",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    // Empty :id segment is matched by the router but the handler
    // captures it as an empty string; we still 204 — the mock runner
    // doesn't care about the id and the cancel is best-effort.
    try testing.expect(resp.status == .no_content or resp.status == .not_found);
}

test "routes: DELETE /sessions//turns/current degrades to 204 or 404" {
    try withMockContext(runTurnCancelMissingId);
}

fn runDelete(_: *harness.MockAgentRunner) anyerror!void {
    const req: http.Request = .{ .method = .DELETE, .target = "/sessions/s1", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "routes: DELETE /sessions/:id returns 204" {
    try withMockContext(runDelete);
}

fn runConfigReload(_: *harness.MockAgentRunner) anyerror!void {
    const before = reload_generation.load(.monotonic);
    const req: http.Request = .{ .method = .POST, .target = "/config/reload", .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.accepted, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"reload\":\"queued\"") != null);
    try testing.expectEqual(before + 1, reload_generation.load(.monotonic));
}

test "routes: POST /config/reload returns 202 and bumps the generation" {
    try withMockContext(runConfigReload);
}

var reload_cb_counter: u32 = 0;

fn reloadTestCallback(ud: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(ud.?));
    counter.* += 1;
}

test "routes: POST /config/reload fires the context's reload_callback per request" {
    reload_cb_counter = 0;
    var mock = harness.MockAgentRunner.init();
    var ctx: Context = .{
        .runner = mock.runner(),
        .reload_callback = reloadTestCallback,
        .reload_userdata = &reload_cb_counter,
    };
    setContext(&ctx);
    defer clearContext();

    const req: http.Request = .{ .method = .POST, .target = "/config/reload", .headers = &.{} };
    _ = try dispatcher.dispatch(&routes, &handlers, req, null);
    _ = try dispatcher.dispatch(&routes, &handlers, req, null);

    try testing.expectEqual(@as(u32, 2), reload_cb_counter);
}

// --- /instances/* tests ---------------------------------------------------

const InstanceTestRig = struct {
    db: db_mod.Db,
    fixed_clock: clock_mod.FixedClock,
    mock: harness.MockAgentRunner,
    ctx: Context,

    fn init() !InstanceTestRig {
        var db = try db_mod.Db.open(testing.allocator, .{ .path = ":memory:" });
        try db_mod.migrations.run(&db);
        return .{
            .db = db,
            .fixed_clock = .{ .value_ns = 1234 },
            .mock = harness.MockAgentRunner.init(),
            .ctx = undefined,
        };
    }

    fn install(self: *InstanceTestRig) void {
        self.ctx = .{
            .runner = self.mock.runner(),
            .db = &self.db,
            .clock = self.fixed_clock.clock(),
            .io = testing.io,
        };
        setContext(&self.ctx);
    }

    fn deinit(self: *InstanceTestRig) void {
        clearContext();
        self.db.close();
    }
};

test "POST /instances/register: creates a row, returns id+token, hashes the token" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const body =
        \\{"kind":"tui","name":"alice","heartbeat_interval_ms":5000}
    ;
    const headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/register",
        .headers = &headers,
        .body = body,
    };

    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.created, resp.status);

    // Parse the response — check the id starts with "tui-" and the
    // token is 64 lowercase hex chars.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const id = obj.get("id").?.string;
    const token = obj.get("token").?.string;
    try testing.expect(std.mem.startsWith(u8, id, "tui-"));
    try testing.expectEqual(@as(usize, 64), token.len);

    // Row exists, has the right fields, stores the hash (not the token).
    var repo = db_mod.InstanceRepo.init(&rig.db);
    const rec = (try repo.get(testing.allocator, id)) orelse return error.TestUnexpectedNull;
    var rec_mut = rec;
    defer freeRecord(testing.allocator, &rec_mut);
    try testing.expectEqual(db_mod.InstanceKind.tui, rec.kind);
    try testing.expectEqualStrings("alice", rec.name);
    try testing.expectEqual(@as(u32, 5000), rec.heartbeat_interval_ms);
    try testing.expectEqual(@as(i128, 1234), rec.connected_at_ns);
    try testing.expectEqual(@as(i128, 1234), rec.last_heartbeat_at_ns);
}

test "POST /instances/register: rejects missing body" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/register",
        .headers = &headers,
        .body = "",
    };
    try testing.expectError(error.BadRequest, dispatcher.dispatch(&routes, &handlers, req, null));
}

test "POST /instances/register: rejects unknown kind" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const body =
        \\{"kind":"martian"}
    ;
    const headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/register",
        .headers = &headers,
        .body = body,
    };
    try testing.expectError(error.BadRequest, dispatcher.dispatch(&routes, &handlers, req, null));
}

test "POST /instances/register: 503 when db is not wired" {
    var mock = harness.MockAgentRunner.init();
    var ctx: Context = .{ .runner = mock.runner() };
    setContext(&ctx);
    defer clearContext();

    const body =
        \\{"kind":"tui"}
    ;
    const headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/register",
        .headers = &headers,
        .body = body,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.service_unavailable, resp.status);
}

test "POST /instances/:id/heartbeat: bumps timestamp and revives evicted record" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    var repo = db_mod.InstanceRepo.init(&rig.db);
    try repo.insert(.{
        .id = "tui-deadbeef",
        .kind = .tui,
        .name = "test",
        .heartbeat_interval_ms = 1000,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
        .evicted_at_ns = 999, // soft-evicted
    });

    rig.fixed_clock.value_ns = 5000;
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/tui-deadbeef/heartbeat",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);

    const rec = (try repo.get(testing.allocator, "tui-deadbeef")) orelse return error.TestUnexpectedNull;
    var rec_mut = rec;
    defer freeRecord(testing.allocator, &rec_mut);
    try testing.expectEqual(@as(i128, 5000), rec.last_heartbeat_at_ns);
    try testing.expectEqual(@as(i128, 0), rec.evicted_at_ns);
}

test "POST /instances/:id/heartbeat: 404 on unknown id" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/ghost-12345678/heartbeat",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.not_found, resp.status);
}

test "DELETE /instances/:id: removes the row; 404 on subsequent delete" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    var repo = db_mod.InstanceRepo.init(&rig.db);
    try repo.insert(.{
        .id = "cli-cafebabe",
        .kind = .cli,
        .connected_at_ns = 0,
        .last_heartbeat_at_ns = 0,
    });

    const req: http.Request = .{
        .method = .DELETE,
        .target = "/instances/cli-cafebabe",
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
    try testing.expect(!(try repo.exists("cli-cafebabe")));

    // Re-delete: row is gone, the auth resolver reports 404.
    const resp2 = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.not_found, resp2.status);
}

/// Local helper to free the strings dup'd by `Repo.get`. Mirrors
/// what `freeRecord` would look like if instances_repo exposed one;
/// inlined here to keep the test self-contained.
fn freeRecord(allocator: std.mem.Allocator, rec: *db_mod.InstanceRecord) void {
    allocator.free(rec.id);
    allocator.free(rec.name);
    allocator.free(rec.agent_id);
    allocator.free(rec.session_id);
}

/// Register an instance via the HTTP route, returning (id, token).
/// Used by the auth-gating tests to land a real token-stamped row
/// the way production would. Caller frees both slices.
fn registerOverHttp(allocator: std.mem.Allocator) !struct { id: []u8, token: []u8 } {
    const body =
        \\{"kind":"tui"}
    ;
    const headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
    const req: http.Request = .{
        .method = .POST,
        .target = "/instances/register",
        .headers = &headers,
        .body = body,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();
    return .{
        .id = try allocator.dupe(u8, parsed.value.object.get("id").?.string),
        .token = try allocator.dupe(u8, parsed.value.object.get("token").?.string),
    };
}

test "POST /instances/:id/heartbeat: rejects requests with no Authorization on a tokened row" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const r = try registerOverHttp(testing.allocator);
    defer testing.allocator.free(r.id);
    defer testing.allocator.free(r.token);

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/instances/{s}/heartbeat", .{r.id});

    const req: http.Request = .{
        .method = .POST,
        .target = target,
        .headers = &.{},
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.unauthorized, resp.status);
}

test "POST /instances/:id/heartbeat: rejects a wrong token" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const r = try registerOverHttp(testing.allocator);
    defer testing.allocator.free(r.id);
    defer testing.allocator.free(r.token);

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/instances/{s}/heartbeat", .{r.id});

    // Same-length but-different token.
    var bad_token: [64]u8 = undefined;
    @memset(&bad_token, 'x');
    var auth_buf: [80]u8 = undefined;
    const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bad_token});
    const headers = [_]http.Header{.{ .name = "authorization", .value = auth_value }};

    const req: http.Request = .{
        .method = .POST,
        .target = target,
        .headers = &headers,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.unauthorized, resp.status);
}

test "POST /instances/:id/heartbeat: matching token is accepted" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const r = try registerOverHttp(testing.allocator);
    defer testing.allocator.free(r.id);
    defer testing.allocator.free(r.token);

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/instances/{s}/heartbeat", .{r.id});

    var auth_buf: [80]u8 = undefined;
    const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{r.token});
    const headers = [_]http.Header{.{ .name = "authorization", .value = auth_value }};

    const req: http.Request = .{
        .method = .POST,
        .target = target,
        .headers = &headers,
    };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);
}

test "DELETE /instances/:id: rejects no-Authorization on a tokened row" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const r = try registerOverHttp(testing.allocator);
    defer testing.allocator.free(r.id);
    defer testing.allocator.free(r.token);

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/instances/{s}", .{r.id});

    const req: http.Request = .{ .method = .DELETE, .target = target, .headers = &.{} };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.unauthorized, resp.status);

    // Row still present.
    var repo = db_mod.InstanceRepo.init(&rig.db);
    try testing.expect(try repo.exists(r.id));
}

test "DELETE /instances/:id: matching token deletes the row" {
    var rig = try InstanceTestRig.init();
    defer rig.deinit();
    rig.install();

    const r = try registerOverHttp(testing.allocator);
    defer testing.allocator.free(r.id);
    defer testing.allocator.free(r.token);

    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/instances/{s}", .{r.id});

    var auth_buf: [80]u8 = undefined;
    const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{r.token});
    const headers = [_]http.Header{.{ .name = "authorization", .value = auth_value }};

    const req: http.Request = .{ .method = .DELETE, .target = target, .headers = &headers };
    const resp = try dispatcher.dispatch(&routes, &handlers, req, null);
    try testing.expectEqual(http.Status.no_content, resp.status);

    var repo = db_mod.InstanceRepo.init(&rig.db);
    try testing.expect(!(try repo.exists(r.id)));
}
