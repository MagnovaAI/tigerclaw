//! Construct a concrete `Provider` from a `ProviderConfig`.
//!
//! `src/llm/provider.zig` is interface-only on purpose — it cannot
//! import any concrete backend without dragging every extension into
//! whatever module reaches it. The factory lives here instead, isolated
//! from the trait. It heap-allocates the concrete impl so the returned
//! `Provider` value (which holds a borrowed `*anyopaque` into that
//! impl) survives across function boundaries.
//!
//! The caller owns the returned `Owned` value and must call
//! `owned.deinit(allocator)` exactly once. That call invokes the
//! provider's own `deinit` (releasing any HTTP client / SSE state) and
//! frees the heap allocation backing the impl.
//!
//! Bedrock is intentionally out of scope for v0.1.0 — it ships in the
//! extension dir for code-locality but the factory does not wire its
//! HTTP path. Asking for `.bedrock` returns `error.NotImplemented`.

const std = @import("std");
const build_options = @import("build_options");
const provider_mod = @import("llm_provider");
const providers = @import("providers/root.zig");

const Provider = provider_mod.Provider;

pub const FactoryError = error{
    /// The selected provider was disabled at build time via
    /// `-Dextensions=`. The caller must adjust their config or rebuild.
    ProviderDisabled,
    /// A provider that exists in the binary but has no live wiring in
    /// v0.1.0 (currently: bedrock). Surfaces a clear error so callers
    /// don't silently fall back to mock.
    NotImplemented,
} || std.mem.Allocator.Error;

pub const ProviderConfig = union(enum) {
    /// Always available. Backed by a slice of canned replies the caller
    /// owns; the mock provider does not copy them.
    mock: MockConfig,
    anthropic: AnthropicConfig,
    openai: OpenAIConfig,
    openrouter: OpenRouterConfig,
    /// Reserved for v0.2.0 — see file doc comment.
    bedrock,
};

pub const MockConfig = struct {
    replies: []const providers.mock.Reply,
};

pub const AnthropicConfig = struct {
    io: std.Io,
    api_key: []const u8,
    /// Override only when targeting a local fake or a self-hosted
    /// proxy. Defaults are picked up by the provider when `null`.
    endpoint: ?[]const u8 = null,
    api_version: ?[]const u8 = null,
    beta_features: ?[]const u8 = null,
};

pub const OpenAIConfig = struct {
    io: std.Io,
    api_key: []const u8,
    endpoint: ?[]const u8 = null,
};

pub const OpenRouterConfig = struct {
    io: std.Io,
    api_key: []const u8,
    endpoint: ?[]const u8 = null,
    http_referer: ?[]const u8 = null,
    app_title: ?[]const u8 = null,
};

/// Owned handle returned by `fromSettings`. Holds the heap allocation
/// backing the concrete impl plus the function that knows how to free
/// it. The `provider` field is the value callers thread through the
/// agent / harness API; it borrows into the same allocation.
pub const Owned = struct {
    provider: Provider,
    impl_ptr: *anyopaque,
    free_fn: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    pub fn deinit(self: Owned, allocator: std.mem.Allocator) void {
        // Provider.deinit releases provider-managed state (HTTP client,
        // SSE buffers); free_fn returns the impl's heap allocation.
        self.provider.deinit();
        self.free_fn(allocator, self.impl_ptr);
    }
};

pub fn fromSettings(
    allocator: std.mem.Allocator,
    cfg: ProviderConfig,
) FactoryError!Owned {
    return switch (cfg) {
        .mock => |m| try makeMock(allocator, m),
        .anthropic => |a| try makeAnthropic(allocator, a),
        .openai => |o| try makeOpenAI(allocator, o),
        .openrouter => |o| try makeOpenRouter(allocator, o),
        .bedrock => error.NotImplemented,
    };
}

fn makeMock(allocator: std.mem.Allocator, m: MockConfig) FactoryError!Owned {
    const impl = try allocator.create(providers.mock.MockProvider);
    impl.* = .{ .replies = m.replies };
    return .{
        .provider = impl.provider(),
        .impl_ptr = impl,
        .free_fn = freeMock,
    };
}

fn freeMock(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const impl: *providers.mock.MockProvider = @ptrCast(@alignCast(ptr));
    allocator.destroy(impl);
}

fn makeAnthropic(
    allocator: std.mem.Allocator,
    a: AnthropicConfig,
) FactoryError!Owned {
    if (!build_options.enable_anthropic) return error.ProviderDisabled;
    const Anthropic = providers.AnthropicProvider;
    const impl = try allocator.create(Anthropic);
    var http: providers.anthropic.HttpSource = .{
        .allocator = allocator,
        .io = a.io,
        .api_key = a.api_key,
    };
    if (a.endpoint) |e| http.endpoint = e;
    if (a.api_version) |v| http.api_version = v;
    if (a.beta_features) |b| http.beta_features = b;
    impl.* = .init(.{ .http = http });
    return .{
        .provider = impl.provider(),
        .impl_ptr = impl,
        .free_fn = freeAnthropic,
    };
}

fn freeAnthropic(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    if (!build_options.enable_anthropic) return;
    const impl: *providers.AnthropicProvider = @ptrCast(@alignCast(ptr));
    allocator.destroy(impl);
}

fn makeOpenRouter(
    allocator: std.mem.Allocator,
    o: OpenRouterConfig,
) FactoryError!Owned {
    if (!build_options.enable_openrouter) return error.ProviderDisabled;
    const OpenRouter = providers.OpenRouterProvider;
    const impl = try allocator.create(OpenRouter);
    var http: providers.openrouter.HttpSource = .{
        .allocator = allocator,
        .io = o.io,
        .api_key = o.api_key,
    };
    if (o.endpoint) |e| http.endpoint = e;
    if (o.http_referer) |r| http.http_referer = r;
    if (o.app_title) |t| http.app_title = t;
    impl.* = .init(.{ .http = http });
    return .{
        .provider = impl.provider(),
        .impl_ptr = impl,
        .free_fn = freeOpenRouter,
    };
}

fn freeOpenRouter(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    if (!build_options.enable_openrouter) return;
    const impl: *providers.OpenRouterProvider = @ptrCast(@alignCast(ptr));
    allocator.destroy(impl);
}

/// OpenAI uses the OpenAI-compatible chat completions endpoint —
/// identical wire format to OpenRouter, just a different host. We
/// reuse the OpenRouter provider pointed at api.openai.com to avoid
/// duplicating ~150 lines of HTTP wiring across two extensions. The
/// `OpenAIProvider` extension stays on `.literal` only for cassette
/// replay; live calls go through the OR-shaped HTTP path.
fn makeOpenAI(
    allocator: std.mem.Allocator,
    o: OpenAIConfig,
) FactoryError!Owned {
    if (!build_options.enable_openrouter) return error.ProviderDisabled;
    const OpenRouter = providers.OpenRouterProvider;
    const impl = try allocator.create(OpenRouter);
    const http: providers.openrouter.HttpSource = .{
        .allocator = allocator,
        .io = o.io,
        .api_key = o.api_key,
        .endpoint = o.endpoint orelse "https://api.openai.com/v1/chat/completions",
    };
    impl.* = .init(.{ .http = http });
    return .{
        .provider = impl.provider(),
        .impl_ptr = impl,
        .free_fn = freeOpenRouter,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "factory: mock returns a usable Provider and deinit frees the impl" {
    const replies = [_]providers.mock.Reply{.{ .text = "hello back" }};
    const owned = try fromSettings(testing.allocator, .{ .mock = .{ .replies = &replies } });
    defer owned.deinit(testing.allocator);

    try testing.expectEqualStrings("mock", owned.provider.name());
}

test "factory: bedrock returns NotImplemented" {
    try testing.expectError(
        error.NotImplemented,
        fromSettings(testing.allocator, .bedrock),
    );
}

test "factory: anthropic returns a Provider when the extension is enabled" {
    if (!build_options.enable_anthropic) return error.SkipZigTest;

    // We don't actually issue an HTTP request here — just construct the
    // provider, observe its name, and free it. The HTTP path is covered
    // by the provider's own tests.
    const owned = try fromSettings(testing.allocator, .{ .anthropic = .{
        .io = testing.io,
        .api_key = "sk-test",
    } });
    defer owned.deinit(testing.allocator);

    try testing.expectEqualStrings("anthropic", owned.provider.name());
}

test "factory: openrouter returns a Provider when the extension is enabled" {
    if (!build_options.enable_openrouter) return error.SkipZigTest;

    const owned = try fromSettings(testing.allocator, .{ .openrouter = .{
        .io = testing.io,
        .api_key = "sk-test",
    } });
    defer owned.deinit(testing.allocator);

    try testing.expectEqualStrings("openrouter", owned.provider.name());
}
