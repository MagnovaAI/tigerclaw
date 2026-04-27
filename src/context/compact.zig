const std = @import("std");

/// An append-only marker recording that a range of transcript entries
/// has been compacted down to a single summary entry. The range is
/// half-open: `[range_start_id, range_end_id)`.
pub const CompactionMarker = struct {
    session_id: []const u8 = "",
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
        for (self.items.items) |m| {
            self.allocator.free(m.session_id);
            self.allocator.free(m.range_start_id);
            self.allocator.free(m.range_end_id);
            self.allocator.free(m.summary_text);
            self.allocator.free(m.summary_entry_id);
        }
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *MarkerLog, m: CompactionMarker) !void {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing.session_id, m.session_id) and
                std.mem.eql(u8, existing.range_start_id, m.range_start_id) and
                std.mem.eql(u8, existing.range_end_id, m.range_end_id)) return;
        }
        const session_id = try self.allocator.dupe(u8, m.session_id);
        errdefer self.allocator.free(session_id);
        const range_start_id = try self.allocator.dupe(u8, m.range_start_id);
        errdefer self.allocator.free(range_start_id);
        const range_end_id = try self.allocator.dupe(u8, m.range_end_id);
        errdefer self.allocator.free(range_end_id);
        const summary_text = try self.allocator.dupe(u8, m.summary_text);
        errdefer self.allocator.free(summary_text);
        const summary_entry_id = try self.allocator.dupe(u8, m.summary_entry_id);
        errdefer self.allocator.free(summary_entry_id);

        try self.items.append(self.allocator, .{
            .session_id = session_id,
            .range_start_id = range_start_id,
            .range_end_id = range_end_id,
            .summary_text = summary_text,
            .summary_entry_id = summary_entry_id,
            .created_at_ms = m.created_at_ms,
        });
    }

    pub fn covers(self: *const MarkerLog, entry_id: []const u8) bool {
        return self.coversSession("", entry_id);
    }

    pub fn coversSession(self: *const MarkerLog, session_id: []const u8, entry_id: []const u8) bool {
        for (self.items.items) |m| {
            if (!std.mem.eql(u8, m.session_id, session_id)) continue;
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
