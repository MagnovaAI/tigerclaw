const std = @import("std");
const engine = @import("ctx_engine");

pub const RegistryError = error{ DuplicateContributor, OutOfMemory };

/// Insertion-order list of ContextContributor handles, deduped by id.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(engine.ContextContributor),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .items = .{ .items = &.{}, .capacity = 0 } };
    }

    pub fn deinit(self: *Registry) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Registry, c: engine.ContextContributor) RegistryError!void {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing.id, c.id)) return error.DuplicateContributor;
        }
        try self.items.append(self.allocator, c);
    }

    pub fn all(self: *const Registry) []const engine.ContextContributor {
        return self.items.items;
    }
};
