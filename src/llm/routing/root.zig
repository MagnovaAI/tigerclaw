//! LLM routing: a static per-request policy plus a fallback-aware
//! dispatcher. Reliability primitives (retry, circuit breaker, rate
//! limiter) live in a sibling `reliability/` directory and compose on
//! top of individual providers, not on top of the router.

const std = @import("std");

pub const policy = @import("policy.zig");
pub const fallback = @import("fallback.zig");
pub const router = @import("router.zig");

pub const Policy = policy.Policy;
pub const Rule = policy.Rule;
pub const Router = router.Router;
pub const Route = router.Route;

test {
    std.testing.refAllDecls(@import("policy.zig"));
    std.testing.refAllDecls(@import("fallback.zig"));
    std.testing.refAllDecls(@import("router.zig"));
}
