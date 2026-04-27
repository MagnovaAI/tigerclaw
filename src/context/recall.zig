const std = @import("std");
const t = @import("ctx_types");
const PlugError = @import("errors").PlugError;

/// Type-erased memory-index interface. Impls (e.g. memory-tigerclaw) set
/// `ptr` to their state struct and `query_fn` to a static function that
/// takes the state pointer back in via `@ptrCast`.
pub const MemoryIndex = struct {
    ptr: *anyopaque,
    query_fn: *const fn (
        self: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
        k: u8,
    ) PlugError![]t.RecallHit,
};

/// Dispatch a recall query to `idx`. Returned slice is caller-owned,
/// freed via the same allocator that `idx.query_fn` used.
pub fn query(
    allocator: std.mem.Allocator,
    idx: MemoryIndex,
    q: []const u8,
    k: u8,
) PlugError![]t.RecallHit {
    return idx.query_fn(idx.ptr, allocator, q, k);
}
