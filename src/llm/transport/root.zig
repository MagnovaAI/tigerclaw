//! Transport layer: SSE parser and the reader adapter that drives it.

const std = @import("std");

pub const sse = @import("sse.zig");
pub const stream = @import("stream.zig");

pub const Event = sse.Event;
pub const Parser = sse.Parser;
pub const Stream = stream.Stream;

test {
    std.testing.refAllDecls(@import("sse.zig"));
    std.testing.refAllDecls(@import("stream.zig"));
}
