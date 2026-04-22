//! Trace file format (schema v2).
//!
//! A trace is a JSON-lines file whose first line is `schema.Envelope` and
//! whose subsequent lines are `span.Span` records. Recorder, replayer,
//! diff, and redact land in follow-up commits.

const std = @import("std");

pub const schema = @import("schema.zig");
pub const span = @import("span.zig");

pub const Envelope = schema.Envelope;
pub const Mode = schema.Mode;
pub const Digest = schema.Digest;
pub const Span = span.Span;
pub const Kind = span.Kind;
pub const Status = span.Status;

pub const schema_version = schema.schema_version;

test {
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("span.zig"));
}
