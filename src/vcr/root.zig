//! VCR cassette layer.
//!
//! Records HTTP request/response pairs to disk and replays them later.
//! The recorder is shaped like `trace/recorder.zig`: header-first, JSON-
//! lines, never closes its writer.

const std = @import("std");

pub const cassette = @import("cassette.zig");
pub const matcher = @import("matcher.zig");
pub const recorder = @import("recorder.zig");
pub const replayer = @import("replayer.zig");

pub const Header = cassette.Header;
pub const Request = cassette.Request;
pub const Response = cassette.Response;
pub const Interaction = cassette.Interaction;
pub const Policy = matcher.Policy;
pub const Recorder = recorder.Recorder;
pub const Cassette = replayer.Cassette;

pub const format_version = cassette.format_version;

test {
    std.testing.refAllDecls(@import("cassette.zig"));
    std.testing.refAllDecls(@import("matcher.zig"));
    std.testing.refAllDecls(@import("recorder.zig"));
    std.testing.refAllDecls(@import("replayer.zig"));
}
