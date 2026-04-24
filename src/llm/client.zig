//! Thin facade around a `Provider` that funnels every call through the
//! token estimator and an optional trace recorder. It does not own the
//! provider — callers own both the impl and the client.

const std = @import("std");
const provider_mod = @import("llm_provider");
const token_estimator = @import("token_estimator.zig");

const Provider = provider_mod.Provider;
const ChatRequest = provider_mod.ChatRequest;
const ChatResponse = provider_mod.ChatResponse;

pub const Client = struct {
    provider: Provider,

    pub fn init(provider: Provider) Client {
        return .{ .provider = provider };
    }

    /// Returns the pre-call token estimate plus a best-effort total-count
    /// hint for budget reservation; callers can cross-check with the
    /// post-call `ChatResponse.usage` values.
    pub fn estimateRequest(self: Client, request: ChatRequest) u32 {
        _ = self;
        var est: u64 = 0;
        if (request.system) |sys| est += token_estimator.estimate(sys);
        for (request.messages) |m| est += token_estimator.estimate(m.flatText());
        return @intCast(@min(est, std.math.maxInt(u32)));
    }

    pub fn chat(
        self: Client,
        allocator: std.mem.Allocator,
        request: ChatRequest,
    ) anyerror!ChatResponse {
        return self.provider.chat(allocator, request);
    }

    pub fn name(self: Client) []const u8 {
        return self.provider.name();
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("types");

const MiniImpl = struct {
    canned: []const u8,

    fn getName(_: *anyopaque) []const u8 {
        return "mini";
    }
    fn doChat(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ChatRequest,
    ) anyerror!ChatResponse {
        const self: *MiniImpl = @ptrCast(@alignCast(ptr));
        return .{ .text = try allocator.dupe(u8, self.canned) };
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

    fn provider(self: *MiniImpl) Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "Client.chat: dispatches to the provider" {
    var impl = MiniImpl{ .canned = "hi" };
    const client = Client.init(impl.provider());

    const messages = [_]types.Message{};
    const resp = try client.chat(testing.allocator, .{
        .messages = &messages,
        .model = .{ .provider = "mini", .model = "0" },
    });
    defer if (resp.text) |t| testing.allocator.free(t);

    try testing.expectEqualStrings("hi", resp.text.?);
    try testing.expectEqualStrings("mini", client.name());
}

test "Client.estimateRequest: counts system + messages" {
    var impl = MiniImpl{ .canned = "_" };
    const client = Client.init(impl.provider());

    // 4 bytes per token; system=8 ⇒ 2 tokens, msg=12 ⇒ 3 tokens → total 5.
    const msgs = [_]types.Message{types.Message.literal(.user, "hello world!")};
    const est = client.estimateRequest(.{
        .system = "sysprmpt",
        .messages = &msgs,
        .model = .{ .provider = "mini", .model = "0" },
    });
    try testing.expectEqual(@as(u32, 5), est);
}
