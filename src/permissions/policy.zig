//! Permissions policy.
//!
//! The permissions subsystem answers one question per action:
//!
//!   > "Before I do X, should I just go ahead, ask the user, or
//!   >  refuse outright?"
//!
//! That answer is computed from two inputs: an `AutonomyLevel`
//! (the coarse global posture the user picked) and per-`ActionKind`
//! `Mode` overrides that let the user dial individual behaviours.
//!
//! This file defines the data. The evaluator in `rules.zig`
//! resolves a concrete (action, target) pair into a `Decision`;
//! `prompt.zig` renders the question when the resolution is
//! `ask`; `approval.zig` remembers previous answers.
//!
//! Design choices worth calling out:
//!
//!   * `AutonomyLevel` is coarse on purpose. Finer control is
//!     available via explicit `Mode` overrides per action kind —
//!     that keeps the defaults legible without forcing every user
//!     to handwrite a policy file.
//!   * There is deliberately no `yolo`/"bypass all" level. A
//!     setting that short-circuits the whole subsystem is a
//!     foot-gun; users who want maximum autonomy can choose
//!     `full` and set specific `Mode.always` overrides.

const std = @import("std");

/// Kinds of action the runtime asks permission for. Deliberately
/// small; new kinds require a code change (and thus a review) so
/// the permissions model does not balloon on accident.
pub const ActionKind = enum {
    /// Read a file (cat, grep, scan, etc.)
    fs_read,
    /// Modify a file (write, create, delete).
    fs_write,
    /// Spawn a subprocess.
    exec,
    /// Initiate a network connection.
    net,
    /// Invoke an LLM tool call that is not otherwise classified.
    tool_call,
};

/// Coarse autonomy posture. Picked once per session (or as a
/// default in settings) and used as the backstop when no explicit
/// per-kind `Mode` is set.
pub const AutonomyLevel = enum {
    /// Observe only: every side-effect kind resolves to `ask` at
    /// minimum; write/exec/net default to `never` so the user
    /// cannot be tricked into a silent action.
    read_only,
    /// Act, but check in for risky kinds. Default.
    supervised,
    /// Free-running within the policy. Only `fs_write` of
    /// denylisted paths and unrecognised tools still prompt.
    full,

    pub fn default() AutonomyLevel {
        return .supervised;
    }
};

/// What the runtime should do when it encounters an action of a
/// given kind. Chosen so the three states are trivially
/// composable: escalations (`always` → `ask` → `never`) work with
/// a simple ordering.
pub const Mode = enum {
    /// Perform the action without prompting.
    always,
    /// Prompt the user; cache the answer if they opt into it.
    ask,
    /// Refuse the action outright. No prompt shown.
    never,

    /// Severity order: a stricter mode wins over a looser one when
    /// two sources conflict (e.g. autonomy says `always`, explicit
    /// override says `ask` → result is `ask`). This is what keeps
    /// user intent additive rather than accidentally permissive.
    pub fn stricter(a: Mode, b: Mode) Mode {
        // .never > .ask > .always
        if (a == .never or b == .never) return .never;
        if (a == .ask or b == .ask) return .ask;
        return .always;
    }
};

/// Optional per-kind override. `null` means "inherit from
/// AutonomyLevel". Users typically set one or two of these (e.g.
/// `.fs_write = .ask` even under `full`) rather than filling all
/// five.
pub const Overrides = struct {
    fs_read: ?Mode = null,
    fs_write: ?Mode = null,
    exec: ?Mode = null,
    net: ?Mode = null,
    tool_call: ?Mode = null,

    pub fn get(self: Overrides, kind: ActionKind) ?Mode {
        return switch (kind) {
            .fs_read => self.fs_read,
            .fs_write => self.fs_write,
            .exec => self.exec,
            .net => self.net,
            .tool_call => self.tool_call,
        };
    }
};

pub const Policy = struct {
    autonomy: AutonomyLevel = .supervised,
    overrides: Overrides = .{},

    /// Default Mode for a kind under the current AutonomyLevel,
    /// ignoring overrides.
    pub fn defaultMode(autonomy: AutonomyLevel, kind: ActionKind) Mode {
        return switch (autonomy) {
            .read_only => switch (kind) {
                .fs_read => .always,
                .fs_write, .exec, .net => .never,
                .tool_call => .ask,
            },
            .supervised => switch (kind) {
                .fs_read => .always,
                .fs_write => .ask,
                .exec => .ask,
                .net => .ask,
                .tool_call => .ask,
            },
            .full => switch (kind) {
                .fs_read => .always,
                .fs_write => .always,
                .exec => .always,
                .net => .always,
                // Unknown/unclassified tool calls still prompt even
                // under full autonomy — cheap belt-and-braces.
                .tool_call => .ask,
            },
        };
    }

    /// Resolve the Mode for a kind, combining autonomy default
    /// and explicit override using the stricter-wins rule.
    pub fn modeFor(self: Policy, kind: ActionKind) Mode {
        const d = Policy.defaultMode(self.autonomy, kind);
        const override = self.overrides.get(kind) orelse return d;
        return Mode.stricter(d, override);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Mode.stricter: never wins over everything" {
    try testing.expectEqual(Mode.never, Mode.stricter(.never, .always));
    try testing.expectEqual(Mode.never, Mode.stricter(.ask, .never));
}

test "Mode.stricter: ask wins over always" {
    try testing.expectEqual(Mode.ask, Mode.stricter(.always, .ask));
    try testing.expectEqual(Mode.ask, Mode.stricter(.ask, .always));
}

test "Policy.defaultMode: read_only refuses all side effects" {
    try testing.expectEqual(Mode.always, Policy.defaultMode(.read_only, .fs_read));
    try testing.expectEqual(Mode.never, Policy.defaultMode(.read_only, .fs_write));
    try testing.expectEqual(Mode.never, Policy.defaultMode(.read_only, .exec));
    try testing.expectEqual(Mode.never, Policy.defaultMode(.read_only, .net));
}

test "Policy.defaultMode: supervised asks for every side effect" {
    try testing.expectEqual(Mode.always, Policy.defaultMode(.supervised, .fs_read));
    try testing.expectEqual(Mode.ask, Policy.defaultMode(.supervised, .fs_write));
    try testing.expectEqual(Mode.ask, Policy.defaultMode(.supervised, .exec));
    try testing.expectEqual(Mode.ask, Policy.defaultMode(.supervised, .net));
}

test "Policy.defaultMode: full still asks for unclassified tools" {
    try testing.expectEqual(Mode.always, Policy.defaultMode(.full, .fs_write));
    try testing.expectEqual(Mode.ask, Policy.defaultMode(.full, .tool_call));
}

test "Policy.modeFor: override can only be stricter than default" {
    const loose = Policy{
        .autonomy = .full,
        .overrides = .{ .fs_write = .ask },
    };
    try testing.expectEqual(Mode.ask, loose.modeFor(.fs_write));

    // Trying to loosen a default with an override does NOT work —
    // stricter wins. Supervised.fs_write defaults to .ask; asking
    // for .always cannot escalate autonomy.
    const sneaky = Policy{
        .autonomy = .supervised,
        .overrides = .{ .fs_write = .always },
    };
    try testing.expectEqual(Mode.ask, sneaky.modeFor(.fs_write));
}
