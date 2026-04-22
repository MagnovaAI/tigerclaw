//! Transport-level fault injection.
//!
//! A `Script` is a caller-built sequence of synthetic errors — one per
//! request, drawn in order. The harness wraps a real provider in an
//! `Injector` during bench or replay mode: each `chat` call either lets
//! the request through or returns the scripted error. Nothing in this
//! module is stochastic; determinism is a hard requirement.

const std = @import("std");
const provider_mod = @import("../provider.zig");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const Fault = union(enum) {
    /// Pass the request through to the wrapped provider.
    pass,
    /// Return the named anyerror.
    inject: anyerror,
};

pub const Script = struct {
    steps: []const Fault,
    cursor: usize = 0,

    pub fn init(steps: []const Fault) Script {
        return .{ .steps = steps };
    }

    pub fn next(self: *Script) Fault {
        if (self.cursor >= self.steps.len) return .pass;
        const step = self.steps[self.cursor];
        self.cursor += 1;
        return step;
    }

    pub fn reset(self: *Script) void {
        self.cursor = 0;
    }
};

pub const Injector = struct {
    inner: Provider,
    script: *Script,

    pub fn init(inner: Provider, script: *Script) Injector {
        return .{ .inner = inner, .script = script };
    }

    pub fn provider(self: *Injector) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getName(ptr: *anyopaque) []const u8 {
        const self: *Injector = @ptrCast(@alignCast(ptr));
        return self.inner.name();
    }

    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *Injector = @ptrCast(@alignCast(ptr));
        const step = self.script.next();
        return switch (step) {
            .pass => self.inner.chat(allocator, request),
            .inject => |err| err,
        };
    }

    fn supportsTools(ptr: *anyopaque) bool {
        const self: *Injector = @ptrCast(@alignCast(ptr));
        return self.inner.supportsNativeTools();
    }

    fn doDeinit(_: *anyopaque) void {}

    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("../../types/root.zig");

const Always = struct {
    reply: []const u8,

    fn getName(_: *anyopaque) []const u8 {
        return "always";
    }
    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *Always = @ptrCast(@alignCast(ptr));
        return .{ .text = try allocator.dupe(u8, self.reply) };
    }
    fn supportsTools(_: *anyopaque) bool {
        return true;
    }
    fn doDeinit(_: *anyopaque) void {}
    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
    fn provider(self: *Always) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn emptyMessages() [0]types.Message {
    return .{};
}

test "Injector: .pass lets the request through" {
    var inner = Always{ .reply = "ok" };
    var script = Script.init(&.{.pass});
    var inj = Injector.init(inner.provider(), &script);

    const msgs = emptyMessages();
    const resp = try inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "always", .model = "x" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("ok", resp.text.?);
}

test "Injector: .inject returns the scripted error" {
    var inner = Always{ .reply = "never" };
    var script = Script.init(&.{.{ .inject = error.Unavailable }});
    var inj = Injector.init(inner.provider(), &script);

    const msgs = emptyMessages();
    try testing.expectError(error.Unavailable, inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "always", .model = "x" },
    }));
}

test "Injector: script advances per call; extras fall back to pass" {
    var inner = Always{ .reply = "ok" };
    const steps = [_]Fault{
        .{ .inject = error.TimedOut },
        .pass,
    };
    var script = Script.init(&steps);
    var inj = Injector.init(inner.provider(), &script);

    const msgs = emptyMessages();

    try testing.expectError(error.TimedOut, inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "always", .model = "x" },
    }));

    const r2 = try inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "always", .model = "x" },
    });
    defer if (r2.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("ok", r2.text.?);

    // Past the script: defaults to pass.
    const r3 = try inj.provider().chat(testing.allocator, .{
        .messages = &msgs,
        .model = .{ .provider = "always", .model = "x" },
    });
    defer if (r3.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("ok", r3.text.?);
}

test "Script.reset rewinds the cursor" {
    var script = Script.init(&.{ .pass, .{ .inject = error.RateLimited } });
    _ = script.next();
    script.reset();
    try testing.expectEqual(@as(usize, 0), script.cursor);
}
