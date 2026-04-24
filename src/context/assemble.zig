const std = @import("std");
const t = @import("ctx_types");

pub const FitResult = struct {
    sections: []t.Section,
    estimated_tokens: u32,
    dropped: []t.DroppedSection,
};

/// Sort `input` into `out` by (priority asc, origin asc). `out.len` must be >= input.len.
pub fn sortSections(out: []t.Section, input: []const t.Section) []t.Section {
    std.debug.assert(out.len >= input.len);
    @memcpy(out[0..input.len], input);
    std.sort.pdq(t.Section, out[0..input.len], {}, cmpSection);
    return out[0..input.len];
}

fn cmpSection(_: void, a: t.Section, b: t.Section) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    return std.mem.lessThan(u8, a.origin, b.origin);
}

/// Greedy fill under budget. Allocates output slices with `allocator`.
/// Caller owns both `sections` and `dropped` slices.
pub fn fit(allocator: std.mem.Allocator, input: []const t.Section, budget: u32) !FitResult {
    const sorted = try allocator.alloc(t.Section, input.len);
    defer allocator.free(sorted);
    _ = sortSections(sorted, input);

    var kept: std.ArrayList(t.Section) = .empty;
    errdefer kept.deinit(allocator);
    var dropped: std.ArrayList(t.DroppedSection) = .empty;
    errdefer dropped.deinit(allocator);

    var used: u32 = 0;
    for (sorted) |s| {
        if (used +| s.token_estimate <= budget) {
            try kept.append(allocator, s);
            used += s.token_estimate;
        } else {
            try dropped.append(allocator, .{ .section = s, .reason = .over_budget });
        }
    }

    return .{
        .sections = try kept.toOwnedSlice(allocator),
        .estimated_tokens = used,
        .dropped = try dropped.toOwnedSlice(allocator),
    };
}
