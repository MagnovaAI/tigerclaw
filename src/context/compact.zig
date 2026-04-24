const std = @import("std");

/// An append-only marker recording that a range of transcript entries
/// has been compacted down to a single summary entry. The range is
/// half-open: `[range_start_id, range_end_id)`.
pub const CompactionMarker = struct {
    range_start_id: []const u8,
    range_end_id: []const u8,
    summary_text: []const u8,
    summary_entry_id: []const u8,
    created_at_ms: i64,
};

/// Append-only log of compaction markers. `append` is idempotent by
/// `(range_start_id, range_end_id)` so replaying a compaction decision
/// does not produce duplicates. `covers(entry_id)` is lexical lookup
/// that assumes entry ids are monotonic strings (which tigerclaw's
/// envelope id scheme guarantees within a session).
pub const MarkerLog = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(CompactionMarker),

    pub fn init(allocator: std.mem.Allocator) MarkerLog {
        return .{ .allocator = allocator, .items = .{ .items = &.{}, .capacity = 0 } };
    }

    pub fn deinit(self: *MarkerLog) void {
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *MarkerLog, m: CompactionMarker) !void {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing.range_start_id, m.range_start_id) and
                std.mem.eql(u8, existing.range_end_id, m.range_end_id)) return;
        }
        try self.items.append(self.allocator, m);
    }

    pub fn covers(self: *const MarkerLog, entry_id: []const u8) bool {
        for (self.items.items) |m| {
            const ge_start = std.mem.order(u8, entry_id, m.range_start_id) != .lt;
            const lt_end = std.mem.order(u8, entry_id, m.range_end_id) == .lt;
            if (ge_start and lt_end) return true;
        }
        return false;
    }

    pub fn all(self: *const MarkerLog) []const CompactionMarker {
        return self.items.items;
    }
};
