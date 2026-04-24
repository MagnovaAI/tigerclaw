//! Context engine — the coordinator.
//!
//! The engine wires together `Window`, `compaction`, `References`,
//! `Hints`, and `compression_feedback`. Callers hand it the raw
//! transcript and a window description; it returns a possibly-
//! compacted transcript plus a compression-feedback record.
//!
//! Keeping the wiring behind one struct lets the agent loop call
//! `engine.prepareForSend(history)` without tracking every
//! sub-piece itself.

const std = @import("std");
const types = @import("types");
const window_mod = @import("window.zig");
const compaction_mod = @import("compaction.zig");
const feedback_mod = @import("compression_feedback.zig");

pub const Options = struct {
    allocator: std.mem.Allocator,
    window: window_mod.Window,
    policy: compaction_mod.Policy = .{},
};

pub const Prepared = struct {
    messages: []types.Message,
    /// Owned hint string; empty if no compaction happened.
    hint: []u8,
    /// What the engine observed, fed into the feedback log.
    feedback: feedback_mod.Record,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        for (self.messages) |m| m.freeOwned(allocator);
        allocator.free(self.messages);
        allocator.free(self.hint);
    }
};

pub const Engine = struct {
    opts: Options,
    feedback: feedback_mod.Log = .{},

    pub fn init(opts: Options) Engine {
        return .{ .opts = opts };
    }

    /// Decide whether to compact, perform it if so, record the
    /// feedback, and return the prepared messages.
    pub fn prepareForSend(
        self: *Engine,
        history: []const types.Message,
    ) !Prepared {
        const before_tokens = self.opts.window.estimateMessages(history);
        const status = self.opts.window.classify(before_tokens);

        // Compact only when we are at pressure or would overflow.
        // Warm and ok states keep the original transcript intact so
        // we do not lose fidelity when there is still headroom.
        const needs_compact = status == .pressure or status == .overflow;
        if (!needs_compact) {
            const copy = try copyMessages(self.opts.allocator, history);
            const empty = try self.opts.allocator.alloc(u8, 0);
            const rec = feedback_mod.Record{
                .before_messages = @intCast(history.len),
                .after_messages = @intCast(history.len),
                .before_tokens = before_tokens,
                .after_tokens = before_tokens,
                .hints_added = 0,
            };
            self.feedback.push(rec);
            return .{ .messages = copy, .hint = empty, .feedback = rec };
        }

        const result = try compaction_mod.compact(self.opts.allocator, history, self.opts.policy);
        const after_tokens = self.opts.window.estimateMessages(result.messages);
        const rec = feedback_mod.Record{
            .before_messages = @intCast(history.len),
            .after_messages = @intCast(result.messages.len),
            .before_tokens = before_tokens,
            .after_tokens = after_tokens,
            .hints_added = if (result.hint.len == 0) 0 else 1,
        };
        self.feedback.push(rec);
        return .{
            .messages = result.messages,
            .hint = result.hint,
            .feedback = rec,
        };
    }

    pub fn feedbackLog(self: *const Engine) *const feedback_mod.Log {
        return &self.feedback;
    }
};

fn copyMessages(allocator: std.mem.Allocator, src: []const types.Message) ![]types.Message {
    const out = try allocator.alloc(types.Message, src.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer for (out[0..written]) |m| m.freeOwned(allocator);
    for (src) |m| {
        out[written] = try types.Message.allocText(allocator, m.role, m.flatText());
        written += 1;
    }
    return out;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Engine: ok status keeps history intact" {
    var e = Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 10_000, .reserve_output_tokens = 1_000 },
    });

    const msgs = [_]types.Message{
        types.Message.literal(.user, "hi"),
        types.Message.literal(.assistant, "hello"),
    };
    var prep = try e.prepareForSend(&msgs);
    defer prep.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), prep.messages.len);
    try testing.expectEqual(@as(usize, 0), prep.hint.len);
    try testing.expectEqual(@as(u32, 0), prep.feedback.hints_added);
}

test "Engine: pressure triggers compaction" {
    // Very tight window so even a small history hits pressure.
    var e = Engine.init(.{
        .allocator = testing.allocator,
        .window = .{ .capacity_tokens = 40, .reserve_output_tokens = 0 },
        .policy = .{ .keep_head = 1, .keep_tail = 1 },
    });

    const msgs = [_]types.Message{
        types.Message.literal(.user, "abcdefghijklmnop"),
        types.Message.literal(.assistant, "qrstuvwxyzabcdef"),
        types.Message.literal(.user, "ghijklmnopqrstuv"),
        types.Message.literal(.assistant, "wxyzabcdefghijkl"),
    };
    var prep = try e.prepareForSend(&msgs);
    defer prep.deinit(testing.allocator);

    try testing.expect(prep.messages.len <= msgs.len);
    try testing.expect(prep.feedback.before_messages == msgs.len);
}
