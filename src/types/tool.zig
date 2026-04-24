//! Tool definition — the *schema* an agent is told it can call.
//!
//! A `Tool` describes a single function available to the LLM. The
//! provider serialises the whole set into its native tool-use API
//! shape (Anthropic `tools`, OpenAI `tools`, etc.), and the model
//! responds with a `ToolCall` whose `arguments_json` is validated
//! at dispatch time against the same schema.

const std = @import("std");

pub const Tool = struct {
    /// Stable, case-sensitive identifier the model references. Must
    /// match `[a-zA-Z0-9_-]+` to satisfy every supported provider.
    name: []const u8,
    /// Human-readable description. The model uses this to decide
    /// *when* to call the tool, so be specific about the effect.
    description: []const u8,
    /// JSON Schema draft-07 describing the accepted arguments, as a
    /// JSON string. Kept as a raw string rather than a typed struct
    /// because the full schema is open-ended and we want providers
    /// to splice it verbatim into their payloads without lossy
    /// round-tripping.
    input_schema_json: []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Tool: fields are preserved exactly (no coercion on strings)" {
    const t: Tool = .{
        .name = "get_current_time",
        .description = "Return the current UTC time as ISO-8601.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{}}",
    };
    try testing.expectEqualStrings("get_current_time", t.name);
    try testing.expectEqualStrings("Return the current UTC time as ISO-8601.", t.description);
    try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", t.input_schema_json);
}
