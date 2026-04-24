const std = @import("std");
const compact = @import("ctx_compact");

test "CompactionMarker fields" {
    const m = compact.CompactionMarker{
        .range_start_id = "e1",
        .range_end_id = "e9",
        .summary_text = "summary",
        .summary_entry_id = "s1",
        .created_at_ms = 1000,
    };
    try std.testing.expectEqualStrings("e1", m.range_start_id);
}

test "MarkerLog append + covers" {
    const allocator = std.testing.allocator;
    var log = compact.MarkerLog.init(allocator);
    defer log.deinit();
    try log.append(.{
        .range_start_id = "e1",
        .range_end_id = "e5",
        .summary_text = "s",
        .summary_entry_id = "sid1",
        .created_at_ms = 1,
    });
    try std.testing.expect(log.covers("e3"));
    try std.testing.expect(!log.covers("e6"));
    try std.testing.expect(log.covers("e1")); // inclusive start
    try std.testing.expect(!log.covers("e5")); // exclusive end
}

test "MarkerLog append is idempotent by (start,end)" {
    const allocator = std.testing.allocator;
    var log = compact.MarkerLog.init(allocator);
    defer log.deinit();
    const m = compact.CompactionMarker{
        .range_start_id = "e1",
        .range_end_id = "e5",
        .summary_text = "s",
        .summary_entry_id = "sid1",
        .created_at_ms = 1,
    };
    try log.append(m);
    try log.append(m); // no-op
    try std.testing.expectEqual(@as(usize, 1), log.all().len);
}
