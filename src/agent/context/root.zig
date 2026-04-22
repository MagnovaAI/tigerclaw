//! Context engine: window budgets, compaction, references, hints,
//! and the compression-feedback ring. The engine coordinates; the
//! individual files define the value types.

const std = @import("std");

pub const engine = @import("engine.zig");
pub const window = @import("window.zig");
pub const compaction = @import("compaction.zig");
pub const references = @import("references.zig");
pub const hints = @import("hints.zig");
pub const compression_feedback = @import("compression_feedback.zig");

pub const Engine = engine.Engine;
pub const Window = window.Window;
pub const WindowStatus = window.Status;
pub const CompactionPolicy = compaction.Policy;
pub const Hints = hints.Hints;
pub const References = references.References;
pub const FeedbackRecord = compression_feedback.Record;
pub const FeedbackLog = compression_feedback.Log;

test {
    std.testing.refAllDecls(@import("engine.zig"));
    std.testing.refAllDecls(@import("window.zig"));
    std.testing.refAllDecls(@import("compaction.zig"));
    std.testing.refAllDecls(@import("references.zig"));
    std.testing.refAllDecls(@import("hints.zig"));
    std.testing.refAllDecls(@import("compression_feedback.zig"));
}
