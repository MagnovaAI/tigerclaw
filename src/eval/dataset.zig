//! Eval dataset.
//!
//! A dataset is a list of `Item`s, each pairing an `input` with
//! a scenario id. The on-disk format is JSONL: one Item per line.
//! We keep this tiny so anyone can author a dataset in `jq` or a
//! shell script; structured editors can layer a schema on top.

const std = @import("std");

pub const Item = struct {
    scenario_id: []const u8,
    input: []const u8,
};

/// Parse a JSONL buffer. Returns a caller-owned slice of Items
/// whose fields alias the input buffer — the caller must keep
/// `bytes` alive for as long as the returned items are read.
pub fn parseJsonl(allocator: std.mem.Allocator, bytes: []const u8) ![]Item {
    // First pass: count non-empty lines to size the slice.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
    }

    const out = try allocator.alloc(Item, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it2 = std.mem.splitScalar(u8, bytes, '\n');
    while (it2.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(Item, allocator, line, .{});
        defer parsed.deinit();
        // Copy strings out of the parse arena into the output
        // allocator so the returned items survive `parsed.deinit`.
        // Use errdefer to cleanup partial allocations on failure.
        const scenario_id = try allocator.dupe(u8, parsed.value.scenario_id);
        errdefer allocator.free(scenario_id);
        const input = try allocator.dupe(u8, parsed.value.input);
        out[idx] = .{
            .scenario_id = scenario_id,
            .input = input,
        };
        idx += 1;
    }

    return out;
}

pub fn free(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |i| {
        allocator.free(i.scenario_id);
        allocator.free(i.input);
    }
    allocator.free(items);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parseJsonl: two-line dataset parses both records" {
    const src =
        \\{"scenario_id":"a","input":"hi"}
        \\{"scenario_id":"b","input":"there"}
    ;
    const items = try parseJsonl(testing.allocator, src);
    defer free(testing.allocator, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", items[0].scenario_id);
    try testing.expectEqualStrings("there", items[1].input);
}

test "parseJsonl: ignores blank lines" {
    const src =
        \\{"scenario_id":"a","input":"hi"}
        \\
        \\
    ;
    const items = try parseJsonl(testing.allocator, src);
    defer free(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
}

test "parseJsonl: invalid line surfaces a parse error" {
    const src = "not-json\n";
    try testing.expectError(error.SyntaxError, parseJsonl(testing.allocator, src));
}
