//! Policy → Decision evaluator.
//!
//! Given a `Policy` and a concrete action (kind + target), return
//! one of three decisions:
//!
//!   * `allow`  — proceed without prompting.
//!   * `ask`    — prompt the user; `prompt.zig` renders the
//!                question and `approval.zig` remembers the answer.
//!   * `deny`   — refuse outright, no prompt.
//!
//! The evaluator is a pure function over policy + target; it does
//! not consult the approval store. That lookup is the caller's
//! next step when the decision is `ask`. Keeping the two layers
//! separate means the rules engine stays easy to reason about and
//! testable without any state.

const std = @import("std");
const policy_mod = @import("policy.zig");

pub const Decision = enum { allow, ask, deny };

/// One action under evaluation. `target` is a short human-readable
/// identifier — a path for fs actions, an argv[0] for exec, a host
/// for net — captured so prompts and audit logs can quote it
/// verbatim. The evaluator itself does not parse `target`; it is
/// pure metadata piped through.
pub const Action = struct {
    kind: policy_mod.ActionKind,
    target: []const u8,
};

pub fn evaluate(policy: policy_mod.Policy, action: Action) Decision {
    return switch (policy.modeFor(action.kind)) {
        .always => .allow,
        .ask => .ask,
        .never => .deny,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "evaluate: supervised + fs_write asks" {
    const p = policy_mod.Policy{ .autonomy = .supervised };
    try testing.expectEqual(Decision.ask, evaluate(p, .{ .kind = .fs_write, .target = "/tmp/a" }));
}

test "evaluate: supervised + fs_read allows" {
    const p = policy_mod.Policy{ .autonomy = .supervised };
    try testing.expectEqual(Decision.allow, evaluate(p, .{ .kind = .fs_read, .target = "/tmp/a" }));
}

test "evaluate: read_only + exec denies" {
    const p = policy_mod.Policy{ .autonomy = .read_only };
    try testing.expectEqual(Decision.deny, evaluate(p, .{ .kind = .exec, .target = "/bin/ls" }));
}

test "evaluate: full + overriding fs_write to ask" {
    const p = policy_mod.Policy{
        .autonomy = .full,
        .overrides = .{ .fs_write = .ask },
    };
    try testing.expectEqual(Decision.ask, evaluate(p, .{ .kind = .fs_write, .target = "/etc/hosts" }));
}

test "evaluate: full tool_call still asks by default" {
    const p = policy_mod.Policy{ .autonomy = .full };
    try testing.expectEqual(
        Decision.ask,
        evaluate(p, .{ .kind = .tool_call, .target = "unknown_tool" }),
    );
}
