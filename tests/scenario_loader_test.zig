//! Integration tests for the scenario v3 loader.
//!
//! The on-disk toy scenarios under `scenarios/` are operator
//! assets; they are not embedded into the test binary because
//! Zig 0.16's `@embedFile` refuses cross-package reads for safety.
//! Instead, these tests keep exact mirrors of the toy scenarios
//! inline. If the on-disk copy drifts, the mirror here should be
//! updated to match — that drift is itself a deliberate act.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const scenario = tigerclaw.scenario;

const coding_refactor_rename =
    \\{
    \\  "scenario_id": "coding_refactor_rename",
    \\  "prompt": "Rename every occurrence of the identifier `foo` to `bar` in example.zig.",
    \\  "assertion_id": "file_contains",
    \\  "threshold": 1.0,
    \\  "artifacts_glob": "*.zig",
    \\  "tags": ["coding", "refactor"],
    \\  "expected_tool_names": ["read", "edit"],
    \\  "max_turns": 8,
    \\  "scenario_schema_version": 3
    \\}
;

const nav_read_and_summarize =
    \\{
    \\  "scenario_id": "nav_read_and_summarize",
    \\  "prompt": "List the files in the workspace and summarise each in one sentence.",
    \\  "assertion_id": "contains_summary",
    \\  "threshold": 0.9,
    \\  "artifacts_glob": "*.md",
    \\  "tags": ["navigation", "summarisation"],
    \\  "expected_tool_names": ["glob", "read"],
    \\  "max_turns": 6,
    \\  "scenario_schema_version": 3
    \\}
;

const data_sql_debug =
    \\{
    \\  "scenario_id": "data_sql_debug",
    \\  "prompt": "Given query.sql, identify the join that causes the incorrect row multiplication and explain the fix.",
    \\  "assertion_id": "mentions_token",
    \\  "threshold": 0.8,
    \\  "artifacts_glob": "*.sql",
    \\  "tags": ["data", "debug"],
    \\  "expected_tool_names": ["read", "grep"],
    \\  "forbid_tool_names": ["bash"],
    \\  "max_turns": 10,
    \\  "scenario_schema_version": 3
    \\}
;

const toys = [_][]const u8{
    coding_refactor_rename,
    nav_read_and_summarize,
    data_sql_debug,
};

test "scenario loader: each toy scenario parses and declares required fields" {
    for (toys) |bytes| {
        var parsed = try scenario.loader.parseOne(testing.allocator, bytes);
        defer parsed.deinit();
        try testing.expect(parsed.value.scenario_id.len > 0);
        try testing.expect(parsed.value.prompt.len > 0);
        try testing.expect(parsed.value.assertion_id.len > 0);
        try testing.expect(parsed.value.threshold >= 0);
        try testing.expect(parsed.value.artifacts_glob.len > 0);
    }
}

test "scenario loader: optional fields default when omitted" {
    const minimal =
        \\{"scenario_id":"m","prompt":"p","assertion_id":"a","threshold":0,"artifacts_glob":"*"}
    ;
    var parsed = try scenario.loader.parseOne(testing.allocator, minimal);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 0), parsed.value.max_turns);
    try testing.expectEqual(@as(u64, 0), parsed.value.cost_budget_micros);
    try testing.expectEqualStrings("", parsed.value.rubric_id);
}

test "scenario loader: toy scenarios include expected_tool_names" {
    var parsed = try scenario.loader.parseOne(testing.allocator, coding_refactor_rename);
    defer parsed.deinit();
    try testing.expect(parsed.value.expected_tool_names.len > 0);
}

test "scenario loader: forbid_tool_names round-trips" {
    var parsed = try scenario.loader.parseOne(testing.allocator, data_sql_debug);
    defer parsed.deinit();
    try testing.expect(parsed.value.forbid_tool_names.len > 0);
    try testing.expectEqualStrings("bash", parsed.value.forbid_tool_names[0]);
}
