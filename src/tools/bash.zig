//! `bash` tool — run a command through the sandbox exec policy.
//!
//! This commit does not actually spawn anything. The tool wires
//! the argv through `sandbox.exec.check` and, on approval, returns
//! a structured `permissions.denied`/`exec.would_spawn` marker so
//! callers can see what *would* have run. Real spawning lands
//! after the sandbox's OS-level backends arrive.
//!
//! Arguments: `{"argv": ["..."], "allow_shell_metachars": false?}`.

const std = @import("std");
const types = @import("../types/root.zig");
const schema = @import("schema.zig");
const sandbox = @import("../sandbox/root.zig");

pub const spec = schema.ToolSpec{
    .name = "bash",
    .description = "Run an argv command through the session's sandbox exec policy.",
    .arguments_schema_json =
    \\{"type":"object","properties":{"argv":{"type":"array","items":{"type":"string"}}},"required":["argv"]}
    ,
    .category = .write,
    .tags = &.{ "exec", "mutating" },
};

pub fn handler(inv: schema.Invocation) anyerror!types.ToolResult {
    var parsed = std.json.parseFromSlice(
        BashArgs,
        inv.allocator,
        inv.call.arguments_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "invalid json arguments");
    };
    defer parsed.deinit();

    if (parsed.value.argv.len == 0) {
        return schema.errResult(inv.allocator, inv.call.id, "tool.args", "argv is empty");
    }

    // Default policy: strict allowlist keyed by the caller. With
    // no registered binaries the check will refuse — callers who
    // want to run something either preseed the allowlist or override
    // this handler in their wiring. Until settings wires per-tool
    // policies, `bash` here is best-read as an audit surface.
    const policy = sandbox.ExecPolicy{
        .binary_allowlist = &.{},
        .max_argv_len = 64,
        .allow_shell_metachars = false,
    };
    const rejection = sandbox.exec.check(policy, parsed.value.argv);
    switch (rejection) {
        .none => return schema.errResult(inv.allocator, inv.call.id, "exec.would_spawn", parsed.value.argv[0]),
        .binary_not_allowlisted => return schema.errResult(inv.allocator, inv.call.id, "permissions.denied", parsed.value.argv[0]),
        .argv_too_long => return schema.errResult(inv.allocator, inv.call.id, "exec.argv_too_long", "argv too long"),
        .argv_empty => return schema.errResult(inv.allocator, inv.call.id, "tool.args", "argv is empty"),
        .shell_metachar_rejected => return schema.errResult(inv.allocator, inv.call.id, "exec.metachar", "shell metachar in argv"),
    }
}

const BashArgs = struct {
    argv: []const []const u8,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "bash: default policy denies unlisted binaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c1", .name = "bash", .arguments_json = "{\"argv\":[\"/bin/ls\"]}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("permissions.denied", result.outcome.err.id);
}

test "bash: metachar in argv is rejected via exec policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{
            .id = "c2",
            .name = "bash",
            .arguments_json = "{\"argv\":[\"/bin/sh\",\"a;b\"]}",
        },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    // Deny wins over metachar check because the default allowlist
    // is empty; this documents the layering: allowlist first, then
    // metachar screen.
    try testing.expectEqualStrings("permissions.denied", result.outcome.err.id);
}

test "bash: empty argv is tool.args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try handler(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace = tmp.dir,
        .call = .{ .id = "c3", .name = "bash", .arguments_json = "{\"argv\":[]}" },
    });
    defer testing.allocator.free(result.call_id);
    defer testing.allocator.free(result.outcome.err.detail);
    try testing.expectEqualStrings("tool.args", result.outcome.err.id);
}
