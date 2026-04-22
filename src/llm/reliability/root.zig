//! Reliability primitives: error classification, bounded retry, rate
//! limiting, and a three-state circuit breaker. Each is deliberately
//! small and clock-injected so tests run without pacing.

const std = @import("std");

pub const error_classifier = @import("error_classifier.zig");
pub const retry = @import("retry.zig");
pub const rate_limit = @import("rate_limit.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const fault_injector = @import("fault_injector.zig");
pub const fault_policy = @import("fault_policy.zig");

pub const Class = error_classifier.Class;
pub const RetryPolicy = retry.Policy;
pub const Limiter = rate_limit.Limiter;
pub const Breaker = circuit_breaker.Breaker;
pub const BreakerState = circuit_breaker.State;
pub const FaultScript = fault_injector.Script;
pub const FaultInjector = fault_injector.Injector;
pub const Fault = fault_injector.Fault;
pub const FaultPolicy = fault_policy.Policy;

test {
    std.testing.refAllDecls(@import("error_classifier.zig"));
    std.testing.refAllDecls(@import("retry.zig"));
    std.testing.refAllDecls(@import("rate_limit.zig"));
    std.testing.refAllDecls(@import("circuit_breaker.zig"));
    std.testing.refAllDecls(@import("fault_injector.zig"));
    std.testing.refAllDecls(@import("fault_policy.zig"));
}
