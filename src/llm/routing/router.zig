//! `Router` dispatches `ChatRequest` onto one of several providers.
//!
//! The router owns a flat slice of `Route { name, provider }` entries.
//! For a given request it asks the `Policy` for a preference-ordered
//! list of names and tries them in turn. A retryable error advances to
//! the next candidate (see `fallback.isRetryable`); any other error is
//! returned to the caller.
//!
//! If nothing in the chain succeeds the router returns
//! `error.NoProvider`.

const std = @import("std");
const provider_mod = @import("../provider.zig");
const policy_mod = @import("policy.zig");
const fallback = @import("fallback.zig");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const Route = struct {
    name: []const u8,
    provider: Provider,
};

pub const Error = error{
    NoProvider,
};

pub const Router = struct {
    routes: []const Route,
    policy: policy_mod.Policy,

    pub fn init(routes: []const Route, policy: policy_mod.Policy) Router {
        return .{ .routes = routes, .policy = policy };
    }

    pub fn chat(
        self: Router,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        const chain = self.policy.chainFor(request.model.provider);
        if (chain.len == 0) return error.NoProvider;

        var last_err: ?anyerror = null;
        for (chain) |name| {
            const route = self.find(name) orelse continue;
            const rv = route.provider.chat(allocator, request);
            if (rv) |resp| return resp else |err| {
                last_err = err;
                if (!fallback.isRetryable(err)) return err;
            }
        }

        return last_err orelse error.NoProvider;
    }

    fn find(self: Router, name: []const u8) ?Route {
        for (self.routes) |r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("../../types/root.zig");

const Always = struct {
    reply: []const u8,

    fn getName(ptr: *anyopaque) []const u8 {
        const self: *Always = @ptrCast(@alignCast(ptr));
        return self.reply;
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
        return false;
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

const AlwaysFails = struct {
    err: anyerror,

    fn getName(_: *anyopaque) []const u8 {
        return "always-fails";
    }
    fn doChat(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *AlwaysFails = @ptrCast(@alignCast(ptr));
        return self.err;
    }
    fn supportsTools(_: *anyopaque) bool {
        return false;
    }
    fn doDeinit(_: *anyopaque) void {}
    const vtable = Provider.VTable{
        .name = getName,
        .chat = doChat,
        .supportsNativeTools = supportsTools,
        .deinit = doDeinit,
    };
    fn provider(self: *AlwaysFails) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn tinyRequest() ChatRequest {
    const empty: []const types.Message = &.{};
    return .{
        .messages = empty,
        .model = .{ .provider = "anthropic", .model = "any" },
    };
}

test "Router: retryable failure falls through to the next provider" {
    var fail = AlwaysFails{ .err = error.Unavailable };
    var ok = Always{ .reply = "bedrock" };

    const routes = [_]Route{
        .{ .name = "primary", .provider = fail.provider() },
        .{ .name = "secondary", .provider = ok.provider() },
    };
    const chain = [_][]const u8{ "primary", "secondary" };
    const policy = policy_mod.Policy{
        .rules = &.{.{ .request_provider = "anthropic", .fallback_chain = &chain }},
    };
    const router = Router.init(&routes, policy);

    const resp = try router.chat(testing.allocator, tinyRequest());
    defer if (resp.text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("bedrock", resp.text.?);
}

test "Router: non-retryable error surfaces immediately" {
    var fail = AlwaysFails{ .err = error.InvalidArgument };
    var ok = Always{ .reply = "never" };

    const routes = [_]Route{
        .{ .name = "primary", .provider = fail.provider() },
        .{ .name = "secondary", .provider = ok.provider() },
    };
    const chain = [_][]const u8{ "primary", "secondary" };
    const policy = policy_mod.Policy{
        .rules = &.{.{ .request_provider = "anthropic", .fallback_chain = &chain }},
    };
    const router = Router.init(&routes, policy);

    try testing.expectError(
        error.InvalidArgument,
        router.chat(testing.allocator, tinyRequest()),
    );
}

test "Router: empty chain returns NoProvider" {
    const routes = [_]Route{};
    const policy = policy_mod.Policy{ .rules = &.{} };
    const router = Router.init(&routes, policy);
    try testing.expectError(error.NoProvider, router.chat(testing.allocator, tinyRequest()));
}

test "Router: all providers fail → last retryable error propagated" {
    var fail1 = AlwaysFails{ .err = error.RateLimited };
    var fail2 = AlwaysFails{ .err = error.TimedOut };

    const routes = [_]Route{
        .{ .name = "a", .provider = fail1.provider() },
        .{ .name = "b", .provider = fail2.provider() },
    };
    const chain = [_][]const u8{ "a", "b" };
    const policy = policy_mod.Policy{
        .rules = &.{.{ .request_provider = "anthropic", .fallback_chain = &chain }},
    };
    const router = Router.init(&routes, policy);
    try testing.expectError(error.TimedOut, router.chat(testing.allocator, tinyRequest()));
}
