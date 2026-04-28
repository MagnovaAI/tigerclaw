//! TUI-side AgentRunner adapter that talks to the gateway over HTTP.
//!
//! The TUI wants the same `AgentRunner` shape as the in-process
//! runner, while the architecture wants every interactive surface to
//! be a localhost gateway client. This adapter is the bridge: `run`
//! POSTs to `/sessions/:id/turns`, parses the SSE frames, and forwards
//! chunks/tool events into the existing TUI sinks.

const std = @import("std");
const http_client = @import("../cli/commands/http_client.zig");
const harness = @import("../harness/root.zig");
const sse_client = @import("sse_client.zig");

pub const GatewayRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    bearer: ?[]const u8 = null,
    in_flight: harness.agent_runner.InFlightCounter = .{},
    mutex: std.Io.Mutex = .init,
    current_session: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_url: []const u8,
        bearer: ?[]const u8,
    ) GatewayRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .base_url = base_url,
            .bearer = bearer,
        };
    }

    pub fn deinit(self: *GatewayRunner) void {
        self.clearCurrentSession();
    }

    pub fn runner(self: *GatewayRunner) harness.agent_runner.AgentRunner {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: harness.agent_runner.VTable = .{
        .run = runFn,
        .cancel = cancelFn,
        .counter = counterFn,
    };

    fn runFn(ctx: *anyopaque, req: harness.agent_runner.TurnRequest) harness.agent_runner.TurnError!harness.agent_runner.TurnResult {
        const self: *GatewayRunner = @ptrCast(@alignCast(ctx));
        return self.run(req);
    }

    fn cancelFn(ctx: *anyopaque, _: harness.agent_runner.TurnId) void {
        const self: *GatewayRunner = @ptrCast(@alignCast(ctx));
        self.cancelCurrent();
    }

    fn counterFn(ctx: *anyopaque) *harness.agent_runner.InFlightCounter {
        const self: *GatewayRunner = @ptrCast(@alignCast(ctx));
        return &self.in_flight;
    }

    fn run(self: *GatewayRunner, req: harness.agent_runner.TurnRequest) harness.agent_runner.TurnError!harness.agent_runner.TurnResult {
        if (req.session_id.len == 0) return error.SessionMissing;

        self.in_flight.begin();
        defer self.in_flight.end();

        self.setCurrentSession(req.session_id) catch return error.OutOfMemory;
        defer self.clearCurrentSession();

        const body_json = std.json.Stringify.valueAlloc(self.allocator, .{
            .agent = req.session_id,
            .message = req.input,
        }, .{}) catch return error.OutOfMemory;
        defer self.allocator.free(body_json);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(
            &url_buf,
            "{s}/sessions/{s}/turns",
            .{ self.base_url, req.session_id },
        ) catch return error.InternalError;

        var sink_ctx = SinkCtx{
            .req = req,
            .parser = sse_client.Parser.init(self.allocator),
        };
        defer sink_ctx.parser.deinit();

        _ = http_client.sendStreaming(
            self.allocator,
            self.io,
            .{
                .method = .POST,
                .url = url,
                .bearer = self.bearer,
                .json_body = body_json,
                .accept = "text/event-stream",
            },
            feedSse,
            &sink_ctx,
            .{},
        ) catch |err| return mapHttpError(err);

        return .{
            .output = "",
            .completed = sink_ctx.completed and !sink_ctx.failed,
        };
    }

    fn setCurrentSession(self: *GatewayRunner, session_id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, session_id);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current_session) |old| self.allocator.free(old);
        self.current_session = owned;
    }

    fn clearCurrentSession(self: *GatewayRunner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current_session) |old| self.allocator.free(old);
        self.current_session = null;
    }

    fn cancelCurrent(self: *GatewayRunner) void {
        const session_id = self.copyCurrentSession() orelse return;

        const base_url = self.allocator.dupe(u8, self.base_url) catch {
            self.allocator.free(session_id);
            return;
        };

        const bearer = if (self.bearer) |token|
            self.allocator.dupe(u8, token) catch {
                self.allocator.free(base_url);
                self.allocator.free(session_id);
                return;
            }
        else
            null;

        const job = self.allocator.create(CancelJob) catch {
            if (bearer) |token| self.allocator.free(token);
            self.allocator.free(base_url);
            self.allocator.free(session_id);
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .base_url = base_url,
            .session_id = session_id,
            .bearer = bearer,
        };

        const thread = std.Thread.spawn(.{}, cancelThreadMain, .{job}) catch {
            job.deinit();
            return;
        };
        thread.detach();
    }

    fn copyCurrentSession(self: *GatewayRunner) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session_id = self.current_session orelse return null;
        return self.allocator.dupe(u8, session_id) catch null;
    }
};

const CancelJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    session_id: []u8,
    bearer: ?[]u8,

    fn deinit(self: *CancelJob) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.session_id);
        if (self.bearer) |token| self.allocator.free(token);
        self.allocator.destroy(self);
    }
};

fn cancelThreadMain(job: *CancelJob) void {
    defer job.deinit();
    cancelTurn(job.allocator, job.io, job.base_url, job.session_id, job.bearer) catch {};
}

const SinkCtx = struct {
    req: harness.agent_runner.TurnRequest,
    parser: sse_client.Parser,
    completed: bool = false,
    failed: bool = false,
};

fn feedSse(ctx: ?*anyopaque, bytes: []const u8) http_client.Error!void {
    const self: *SinkCtx = @ptrCast(@alignCast(ctx.?));
    self.parser.feed(bytes, sinkEvent, self) catch return error.InvalidResponse;
}

fn sinkEvent(ctx: ?*anyopaque, event: sse_client.Event) void {
    const self: *SinkCtx = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .chunk => |text| {
            if (self.req.stream_sink) |sink| sink(self.req.stream_sink_ctx, text);
        },
        .tool_start => |tool| {
            if (self.req.tool_event_sink) |sink| sink(self.req.tool_event_sink_ctx, .{
                .started = .{ .id = tool.id, .name = tool.name },
            });
        },
        .tool_progress => |tp| {
            if (self.req.tool_event_sink) |sink| sink(self.req.tool_event_sink_ctx, .{
                .progress = .{
                    .id = tp.id,
                    .stream = switch (tp.stream) {
                        .stdout => .stdout,
                        .stderr => .stderr,
                    },
                    .chunk = tp.chunk,
                },
            });
        },
        .tool_done => |tool| {
            if (self.req.tool_event_sink) |sink| sink(self.req.tool_event_sink_ctx, .{
                .finished = .{
                    .id = tool.id,
                    .name = tool.name,
                    .kind = .{ .text = tool.output },
                },
            });
        },
        .done => self.completed = true,
        .err => |msg| {
            self.failed = true;
            if (self.req.stream_sink) |sink| sink(self.req.stream_sink_ctx, msg);
        },
    }
}

fn cancelTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    bearer: ?[]const u8,
) !void {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/sessions/{s}/turns/current",
        .{ base_url, session_id },
    ) catch return error.UrlTooLong;

    _ = try http_client.send(
        allocator,
        io,
        .{ .method = .DELETE, .url = url, .bearer = bearer },
        null,
        .{},
    );
}

fn mapHttpError(err: http_client.Error) harness.agent_runner.TurnError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GatewayDown => error.GatewayDown,
        error.Unauthorized,
        error.BadRequest,
        error.InternalError,
        error.InvalidResponse,
        => error.InternalError,
    };
}
