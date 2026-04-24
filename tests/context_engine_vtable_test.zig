const std = @import("std");
const engine_mod = @import("ctx_engine");

test "ContextEngineVTable has required fields" {
    const V = engine_mod.ContextEngineVTable;
    inline for (.{ "bootstrap", "ingest", "assemble", "after_turn", "maintain", "compact", "recall", "dispose" }) |name| {
        if (!@hasField(V, name)) @panic("missing vtable field: " ++ name);
    }
}

test "ContextContributorVTable has required fields" {
    const V = engine_mod.ContextContributorVTable;
    inline for (.{ "band", "contribute", "dispose" }) |name| {
        if (!@hasField(V, name)) @panic("missing contributor vtable field: " ++ name);
    }
}

test "ContextEngine handle has ptr and vtable" {
    const H = engine_mod.ContextEngine;
    try std.testing.expect(@hasField(H, "ptr"));
    try std.testing.expect(@hasField(H, "vtable"));
}

test "ContextContributor handle has id, ptr, vtable" {
    const H = engine_mod.ContextContributor;
    try std.testing.expect(@hasField(H, "id"));
    try std.testing.expect(@hasField(H, "ptr"));
    try std.testing.expect(@hasField(H, "vtable"));
}
