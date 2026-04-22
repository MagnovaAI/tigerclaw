//! `clock_now` — echo a caller-supplied timestamp back to the
//! agent. The runtime wiring injects the current session-clock
//! reading through the arguments JSON so the tool is pure with
//! respect to its inputs — replays feed the same number and get
//! the same answer. Zig 0.16 does not expose a free-standing
//! wall-clock sampler that the tool layer can call without an
//! `Io` handle; making the tool read globals would also violate
//! the determinism rules the mode policy exists to enforce.
//!
//! Arguments: `{"now_ns": <i128>}`.
//! Output: the decimal integer that was passed in.

const std = @import("std");
const types = @import("types");
const schema = @import("schema.zig");

pub const spec = schema.ToolSpec{
    .name = "clock_now",
    .description = "Echo the session clock's current nanoseconds, as supplied by the runtime.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"now_ns":{"type":"integer"}},"required":["now_ns"]}
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

    const s = try std.fmt.allocPrint(inv.allocator, "{d}", .{parsed.value.now_ns});
    defer inv.allocator.free(s);
    return schema.okResult(inv.allocator, inv.call.id, s);
}

const Args = struct {
    now_ns: i128,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "clock_now: echoes the injected timestamp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "clock_now", .arguments_json = "{\"now_ns\":1234567890}" },
    });
    defer testing.allocator.free(r.call_id);
    defer testing.allocator.free(r.outcome.ok);
    try testing.expectEqualStrings("1234567890", r.outcome.ok);
}

test "clock_now: same input is deterministic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const call = types.ToolCall{
        .id = "c",
        .name = "clock_now",
        .arguments_json = "{\"now_ns\":42}",
    };
    const a = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(a.call_id);
    defer testing.allocator.free(a.outcome.ok);
    const b = try handler(.{ .allocator = testing.allocator, .io = testing.io, .workspace = tmp.dir, .call = call });
    defer testing.allocator.free(b.call_id);
    defer testing.allocator.free(b.outcome.ok);
    try testing.expectEqualStrings(a.outcome.ok, b.outcome.ok);
}
