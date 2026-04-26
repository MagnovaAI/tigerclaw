//! Transport layer: SSE parser, reader adapter, and shared HTTP helpers.
//!
//! Everything provider extensions need to drive an SSE-backed chat
//! stream cooperatively (with cancel) and survive half-open
//! connections (with socket timeouts). Provider-agnostic — Anthropic,
//! OpenAI, OpenRouter, etc. all build on these primitives so cancel
//! and timeout behaviour is consistent across backends.

const std = @import("std");

pub const sse = @import("sse.zig");
pub const stream = @import("stream.zig");
pub const http = @import("http.zig");

pub const Event = sse.Event;
pub const Parser = sse.Parser;
pub const Stream = stream.Stream;
pub const StreamError = stream.StreamError;

pub const applySocketTimeouts = http.applySocketTimeouts;
pub const applyDefaultSocketTimeouts = http.applyDefaultSocketTimeouts;

test {
    std.testing.refAllDecls(@import("sse.zig"));
    std.testing.refAllDecls(@import("stream.zig"));
    std.testing.refAllDecls(@import("http.zig"));
}
