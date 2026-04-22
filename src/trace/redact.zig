//! Redacts secret-bearing fields from a `Span`'s `attributes_json`.
//!
//! Two entry points:
//!
//! - `redactSpan`: returns a copy of the span whose `attributes_json`
//!   has been rewritten with secret values replaced by `"***"`. The
//!   rest of the span (id, name, parent, timing) is preserved.
//! - `redactAttributesJson`: same rewrite applied to a bare JSON object
//!   string. Shared with `settings/secrets.zig` — the canonical suffix
//!   list lives there.

const std = @import("std");
const span_mod = @import("span.zig");
const secrets = @import("../settings/secrets.zig");

pub const redaction = secrets.redaction;

pub fn redactAttributesJson(
    allocator: std.mem.Allocator,
    attrs_json: []const u8,
) ![]u8 {
    return secrets.redact(allocator, attrs_json);
}

/// Returns a span with its `attributes_json` rewritten. The returned
/// span borrows the input's string fields (id, name, parent_id,
/// trace_id); only `attributes_json` is freshly allocated. Caller frees
/// with `freeRedactedSpan`.
pub fn redactSpan(
    allocator: std.mem.Allocator,
    span: span_mod.Span,
) !span_mod.Span {
    var out = span;
    if (span.attributes_json) |attrs| {
        out.attributes_json = try redactAttributesJson(allocator, attrs);
    }
    return out;
}

pub fn freeRedactedSpan(
    allocator: std.mem.Allocator,
    original: span_mod.Span,
    redacted: span_mod.Span,
) void {
    // Only the attributes_json slot might have been allocated here; and
    // only if the original had one to begin with.
    if (original.attributes_json == null) return;
    if (redacted.attributes_json) |owned| allocator.free(owned);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "redactAttributesJson: replaces secret values in an object" {
    const input = "{\"openai_api_key\":\"sk-live\",\"path\":\"/tmp/x\"}";
    const out = try redactAttributesJson(testing.allocator, input);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "sk-live") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"***\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"/tmp/x\"") != null);
}

test "redactSpan: rewrites attributes and leaves other fields alone" {
    const original = span_mod.Span{
        .id = "s",
        .trace_id = "t",
        .kind = .tool_call,
        .name = "chat",
        .started_at_ns = 0,
        .finished_at_ns = 1,
        .attributes_json = "{\"anthropic_api_key\":\"sk-ant\",\"model\":\"opus\"}",
    };

    const redacted = try redactSpan(testing.allocator, original);
    defer freeRedactedSpan(testing.allocator, original, redacted);

    try testing.expectEqualStrings("s", redacted.id);
    try testing.expectEqualStrings("chat", redacted.name);
    try testing.expect(std.mem.indexOf(u8, redacted.attributes_json.?, "sk-ant") == null);
    try testing.expect(std.mem.indexOf(u8, redacted.attributes_json.?, "\"model\":\"opus\"") != null);
}

test "redactSpan: attributes_json is null → output is null" {
    const original = span_mod.Span{
        .id = "s",
        .trace_id = "t",
        .kind = .turn,
        .name = "turn-1",
        .started_at_ns = 0,
        .finished_at_ns = 1,
    };

    const redacted = try redactSpan(testing.allocator, original);
    defer freeRedactedSpan(testing.allocator, original, redacted);

    try testing.expect(redacted.attributes_json == null);
}
