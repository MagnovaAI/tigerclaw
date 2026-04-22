//! `cost_check` — read a ledger's current spent/pending totals.
//!
//! The tool exists so the agent can self-gate expensive work:
//! "check the budget before launching a long tool chain". The
//! handler accepts numeric totals as arguments (supplied by the
//! runtime wiring, not the model); this keeps the tool pure.
//!
//! Arguments: `{"spent_micros": <u64>, "pending_micros": <u64>}`.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "cost_check",
    .description = "Report the session ledger totals in micro-USD.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"spent_micros":{"type":"integer"},"pending_micros":{"type":"integer"}},"required":["spent_micros","pending_micros"]}
    ,
    .category = .compute,
    .tags = &.{"util"},
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        Args,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

    const total = parsed.value.spent_micros +| parsed.value.pending_micros;
    const payload = try std.fmt.allocPrint(
        inv.allocator,
        "{{\"spent\":{d},\"pending\":{d},\"committed\":{d}}}",
        .{ parsed.value.spent_micros, parsed.value.pending_micros, total },
    );
    defer inv.allocator.free(payload);
    return schema.okResult(inv.allocator, inv.call.id, payload);
}

const Args = struct {
    spent_micros: u64,
    pending_micros: u64,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "cost_check: emits committed = spent + pending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c", .name = "cost_check", .arguments_json = "{\"spent_micros\":100,\"pending_micros\":25}" },
    });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.ok);
    try testing.expect(std.mem.indexOf(u8, r.outcome.ok, "\"committed\":125") != null);
}
