//! Approval prompt model.
//!
//! When `rules.evaluate` returns `.ask`, the runtime wraps the
//! pending action in a `Prompt` and hands it to the UI layer (CLI
//! confirmation, TUI modal, or an API call into another process).
//! The UI returns a `Response` which the runtime uses to:
//!
//!   1. decide whether to proceed with the current action, and
//!   2. maybe cache the answer in `approval.zig` if the user opted
//!      into "remember this".
//!
//! Keeping the prompt as a *value* (rather than hard-wiring stdin
//! in this layer) means the same data path serves a CLI in
//! interactive mode, a headless test injector, and a future IDE
//! integration — each with its own front-end.

const std = @import("std");
const policy_mod = @import("policy.zig");

/// A question to present to the user.
///
/// `reason` is optional free-form context (e.g. "editing
/// /etc/hosts"); it is shown verbatim, never parsed.
pub const Prompt = struct {
    kind: policy_mod.ActionKind,
    target: []const u8,
    reason: []const u8 = "",
};

/// User's answer plus their remember-preference.
pub const Response = struct {
    approved: bool,
    remember: Scope = .once,

    /// Convenience for CLI flags that treat every answer as
    /// session-scoped unless explicitly elevated.
    pub fn deny() Response {
        return .{ .approved = false, .remember = .once };
    }
    pub fn allowOnce() Response {
        return .{ .approved = true, .remember = .once };
    }
    pub fn allowSession() Response {
        return .{ .approved = true, .remember = .session };
    }
};

/// How long the user's decision applies. Scope is a first-class
/// field because the difference between "yes this one time" and
/// "yes always for this session" is the difference between
/// convenient and disastrous.
pub const Scope = enum {
    /// Apply only to the current action. No caching.
    once,
    /// Apply for the rest of the current session. Evicted on
    /// session exit; never persisted to disk.
    session,
    /// Persist across sessions (future: `approval.zig` grows a
    /// writer for this). Present in the enum so the UI layer can
    /// offer it; today it behaves like `session`.
    persistent,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Response.deny: approval false, scope once" {
    const r = Response.deny();
    try testing.expect(!r.approved);
    try testing.expectEqual(Scope.once, r.remember);
}

test "Response.allowOnce / allowSession: scope reflects caller intent" {
    const a = Response.allowOnce();
    try testing.expect(a.approved);
    try testing.expectEqual(Scope.once, a.remember);

    const b = Response.allowSession();
    try testing.expect(b.approved);
    try testing.expectEqual(Scope.session, b.remember);
}

test "Prompt: reason defaults to empty string" {
    const p = Prompt{ .kind = .fs_write, .target = "/tmp/a" };
    try testing.expectEqualStrings("", p.reason);
}
