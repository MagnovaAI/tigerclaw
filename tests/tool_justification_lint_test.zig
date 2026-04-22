//! Tool justification lint.
//!
//! Every built-in tool must declare a Category (1/2/3/4) and the
//! default set must be unique by name. If either invariant breaks,
//! CI fails.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const tools = tigerclaw.tools;

test "justification: every built-in tool declares a category in range" {
    for (tools.builtinTools()) |t| {
        const n = @intFromEnum(t.spec.category);
        if (n < 1 or n > 4) {
            std.debug.print("tool {s} has invalid category {d}\n", .{ t.spec.name, n });
            try testing.expect(false);
        }
    }
}

test "justification: built-in tool names are unique" {
    const list = tools.builtinTools();
    for (list, 0..) |a, i| {
        for (list[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.spec.name, b.spec.name)) {
                std.debug.print("duplicate tool name: {s}\n", .{a.spec.name});
                try testing.expect(false);
            }
        }
    }
}

test "justification: every built-in tool has a non-empty description" {
    for (tools.builtinTools()) |t| {
        try testing.expect(t.spec.description.len > 0);
    }
}
