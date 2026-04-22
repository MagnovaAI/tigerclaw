//! Scenario v3 JSON loader.
//!
//! A scenario is a YAML/JSON file describing one unit of work the
//! bench or eval subsystem will run: a prompt, an assertion id,
//! a score threshold, and a glob describing which artefacts to
//! capture. The full v3 schema has 15 fields; this commit wires
//! the five required base fields and stubs the remaining ten as
//! default-inactive so the file format is forward-compatible.
//!
//! Format chosen: JSON for portability; a tiny YAML dialect may
//! land later, but every real runner today writes JSON and the
//! bench subsystem reads it the same way.

const std = @import("std");

/// The v3 schema version we understand. Hash-guarded elsewhere.
pub const schema_version: u32 = 3;

/// Five required base fields + ten stub fields, all declared with
/// defaults so omitted entries parse cleanly.
pub const Scenario = struct {
    // Required base fields.
    scenario_id: []const u8,
    prompt: []const u8,
    assertion_id: []const u8,
    threshold: f64,
    artifacts_glob: []const u8,

    // Optional v3 stubs; default-inactive. These do nothing in
    // this commit but ensure the loader does not reject files
    // that include them. The bench runner (Commit 43) consumes
    // the ones it knows about.
    tags: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    expected_tool_names: []const []const u8 = &.{},
    forbid_tool_names: []const []const u8 = &.{},
    max_turns: u32 = 0,
    time_budget_ms: u32 = 0,
    cost_budget_micros: u64 = 0,
    rubric_id: []const u8 = "",
    witness_source: []const u8 = "",
    scenario_schema_version: u32 = schema_version,
};

pub const ParseError = error{
    UnsupportedScenarioVersion,
} || std.json.ParseError(std.json.Scanner);

/// Parse a single scenario. Returns a `Parsed` wrapper the caller
/// owns; the scenario's slices live inside its arena.
pub fn parseOne(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ParseError!std.json.Parsed(Scenario) {
    const parsed = try std.json.parseFromSlice(Scenario, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    if (parsed.value.scenario_schema_version > schema_version) {
        parsed.deinit();
        return ParseError.UnsupportedScenarioVersion;
    }
    return parsed;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "loader: base fields parse and stubs default" {
    const json =
        \\{
        \\  "scenario_id":"demo",
        \\  "prompt":"hello",
        \\  "assertion_id":"eq",
        \\  "threshold":0.9,
        \\  "artifacts_glob":"*.txt"
        \\}
    ;
    var parsed = try parseOne(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("demo", parsed.value.scenario_id);
    try testing.expectEqual(@as(f64, 0.9), parsed.value.threshold);
    try testing.expectEqual(@as(u32, 0), parsed.value.max_turns);
    try testing.expectEqualStrings("", parsed.value.witness_source);
    try testing.expectEqual(schema_version, parsed.value.scenario_schema_version);
}

test "loader: rejects newer schema versions" {
    const json =
        \\{
        \\  "scenario_id":"d","prompt":"p","assertion_id":"eq","threshold":0,"artifacts_glob":"*",
        \\  "scenario_schema_version": 99
        \\}
    ;
    try testing.expectError(
        ParseError.UnsupportedScenarioVersion,
        parseOne(testing.allocator, json),
    );
}

test "loader: ignores unknown fields for forward compat" {
    const json =
        \\{"scenario_id":"d","prompt":"p","assertion_id":"eq","threshold":0,"artifacts_glob":"*","future":true}
    ;
    var parsed = try parseOne(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("d", parsed.value.scenario_id);
}
