//! Permissions subsystem.
//!
//! Flow:
//!
//!   Action → evaluate(Policy, Action) → Decision
//!     .allow → proceed
//!     .deny  → refuse
//!     .ask   → check approval.Store for a cached answer
//!             cached   → reuse it
//!             missing  → build a Prompt, hand it to the UI, get
//!                        a Response, record it, return the answer
//!
//! This file bundles those pieces into one `Permissions` facade so
//! callers only import one module. It also defines the `Responder`
//! vtable that the UI layer implements — stdin, a TUI, an IPC
//! endpoint, anything that can turn a `Prompt` into a `Response`.

const std = @import("std");

pub const policy = @import("policy.zig");
pub const rules = @import("rules.zig");
pub const prompt = @import("prompt.zig");
pub const approval = @import("approval.zig");

pub const Policy = policy.Policy;
pub const AutonomyLevel = policy.AutonomyLevel;
pub const ActionKind = policy.ActionKind;
pub const Mode = policy.Mode;
pub const Overrides = policy.Overrides;
pub const Action = rules.Action;
pub const Decision = rules.Decision;
pub const Prompt = prompt.Prompt;
pub const Response = prompt.Response;
pub const Scope = prompt.Scope;
pub const Store = approval.Store;

/// Front-end callback that turns a prompt into a response. UI
/// layers implement this. `ptr` is the impl struct; callers own
/// that struct (standard vtable rule — see ARCHITECTURE.md).
pub const Responder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ask: *const fn (ctx: *anyopaque, p: Prompt) anyerror!Response,
    };

    pub fn ask(self: Responder, p: Prompt) !Response {
        return self.vtable.ask(self.ptr, p);
    }
};

/// Outcome of a `check` call. `approved=true` means the caller may
/// proceed; `approved=false` means refuse. `prompted=true` means
/// the user was actually asked (vs. cache/fast-path); exposed so
/// the runtime can log prompt counts.
pub const CheckOutcome = struct {
    approved: bool,
    prompted: bool,
};

/// Combined facade: policy + cache + responder. The harness owns
/// one per session.
pub const Permissions = struct {
    policy_val: Policy,
    store: *Store,
    responder: Responder,

    pub fn init(policy_val: Policy, store: *Store, responder: Responder) Permissions {
        return .{
            .policy_val = policy_val,
            .store = store,
            .responder = responder,
        };
    }

    /// Decide whether `action` may proceed, possibly prompting the
    /// user. Pure outcome struct so callers do not have to branch
    /// on error values for the common "user said no" case.
    pub fn check(self: *Permissions, action: Action) !CheckOutcome {
        switch (rules.evaluate(self.policy_val, action)) {
            .allow => return .{ .approved = true, .prompted = false },
            .deny => return .{ .approved = false, .prompted = false },
            .ask => {
                const key = approval.Key{ .kind = action.kind, .target = action.target };
                if (try self.store.lookup(key)) |cached| {
                    return .{ .approved = cached.approved, .prompted = false };
                }
                const resp = try self.responder.ask(.{
                    .kind = action.kind,
                    .target = action.target,
                });
                try self.store.record(key, resp);
                return .{ .approved = resp.approved, .prompted = true };
            },
        }
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Test responder that records the last prompt and returns a
/// caller-controlled response. Used below and in the integration
/// test to isolate permissions logic from any UI.
const FakeResponder = struct {
    last_target: []const u8 = "",
    last_kind: ActionKind = .fs_read,
    reply: Response = .{ .approved = false, .remember = .once },

    fn ask(ptr: *anyopaque, p: Prompt) anyerror!Response {
        const self: *FakeResponder = @ptrCast(@alignCast(ptr));
        self.last_target = p.target;
        self.last_kind = p.kind;
        return self.reply;
    }
    fn responder(self: *FakeResponder) Responder {
        return .{ .ptr = self, .vtable = &.{ .ask = ask } };
    }
};

test "Permissions: allow path does not prompt" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var fr = FakeResponder{};
    var perms = Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        fr.responder(),
    );

    const outcome = try perms.check(.{ .kind = .fs_read, .target = "/tmp/a" });
    try testing.expect(outcome.approved);
    try testing.expect(!outcome.prompted);
}

test "Permissions: deny path does not prompt" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var fr = FakeResponder{};
    var perms = Permissions.init(
        .{ .autonomy = .read_only },
        &store,
        fr.responder(),
    );

    const outcome = try perms.check(.{ .kind = .exec, .target = "/bin/rm" });
    try testing.expect(!outcome.approved);
    try testing.expect(!outcome.prompted);
}

test "Permissions: ask path prompts, then caches the session answer" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var fr = FakeResponder{ .reply = Response.allowSession() };
    var perms = Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        fr.responder(),
    );

    const first = try perms.check(.{ .kind = .fs_write, .target = "/tmp/a" });
    try testing.expect(first.approved);
    try testing.expect(first.prompted);
    try testing.expectEqualStrings("/tmp/a", fr.last_target);

    // Second call with the same key must NOT re-prompt.
    fr.last_target = "";
    const second = try perms.check(.{ .kind = .fs_write, .target = "/tmp/a" });
    try testing.expect(second.approved);
    try testing.expect(!second.prompted);
    try testing.expectEqualStrings("", fr.last_target);
}

test "Permissions: allow_once does not leak to a second request" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var fr = FakeResponder{ .reply = Response.allowOnce() };
    var perms = Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        fr.responder(),
    );

    const first = try perms.check(.{ .kind = .fs_write, .target = "/tmp/a" });
    try testing.expect(first.approved);
    try testing.expect(first.prompted);

    const second = try perms.check(.{ .kind = .fs_write, .target = "/tmp/a" });
    // Still `approved` because the fake replies allowOnce again, but
    // crucially the prompt was re-invoked — that is the whole point
    // of `.once`.
    try testing.expect(second.prompted);
}

test {
    std.testing.refAllDecls(@import("policy.zig"));
    std.testing.refAllDecls(@import("rules.zig"));
    std.testing.refAllDecls(@import("prompt.zig"));
    std.testing.refAllDecls(@import("approval.zig"));
}
