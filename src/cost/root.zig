//! Cost subsystem.
//!
//!   * `pricing`       — `ModelPrice` table + integer micro-USD
//!                       arithmetic (ceiling rounding).
//!   * `usage_pricing` — price a `types.TokenUsage` against a
//!                       table, returning a bucketed breakdown.
//!   * `ledger`        — two-phase (reserve/commit/release)
//!                       thread-safe budget enforcer.
//!   * `reporter`      — per-model aggregation for UI/logs.
//!
//! Providers wire it up like this:
//!
//!   1. Before a call, `reserve(upper_bound)` to hold headroom.
//!   2. After the call, `commitUsage(table, model, usage, res)`
//!      to settle the reservation and bump `spent`.
//!   3. Simultaneously, `Reporter.record` to break it down by
//!      model for the report.
//!
//! Both parts are independent — the ledger alone enforces the
//! budget, the reporter alone drives dashboards.

const std = @import("std");

pub const pricing = @import("pricing.zig");
pub const usage_pricing = @import("usage_pricing.zig");
pub const ledger = @import("ledger.zig");
pub const reporter = @import("reporter.zig");

pub const ModelPrice = pricing.ModelPrice;
pub const Priced = usage_pricing.Priced;
pub const Ledger = ledger.Ledger;
pub const Reservation = ledger.Reservation;
pub const Totals = ledger.Totals;
pub const Reporter = reporter.Reporter;
pub const ModelTotals = reporter.ModelTotals;

test {
    std.testing.refAllDecls(@import("pricing.zig"));
    std.testing.refAllDecls(@import("usage_pricing.zig"));
    std.testing.refAllDecls(@import("ledger.zig"));
    std.testing.refAllDecls(@import("reporter.zig"));
}
