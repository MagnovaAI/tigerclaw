//! Trace file format (schema v2).
//!
//! A trace is a JSON-lines file whose first line is `schema.Envelope` and
//! whose subsequent lines are `span.Span` records. Recorder writes;
//! replayer reads; diff compares two span streams structurally; fixture
//! builds in-memory traces for tests; exporter renders a compact human
//! summary.

const std = @import("std");

pub const schema = @import("schema.zig");
pub const span = @import("span.zig");
pub const recorder = @import("recorder.zig");
pub const replayer = @import("replayer.zig");
pub const diff = @import("diff.zig");
pub const fixture = @import("fixture.zig");
pub const exporter = @import("exporter.zig");

pub const Envelope = schema.Envelope;
pub const Mode = schema.Mode;
pub const Digest = schema.Digest;
pub const Span = span.Span;
pub const Kind = span.Kind;
pub const Status = span.Status;
pub const Recorder = recorder.Recorder;
pub const Replay = replayer.Replay;

pub const schema_version = schema.schema_version;

test {
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("span.zig"));
    std.testing.refAllDecls(@import("recorder.zig"));
    std.testing.refAllDecls(@import("replayer.zig"));
    std.testing.refAllDecls(@import("diff.zig"));
    std.testing.refAllDecls(@import("fixture.zig"));
    std.testing.refAllDecls(@import("exporter.zig"));
}
