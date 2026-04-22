//! Static user-facing strings.
//!
//! Anything the user reads lives here, so copy reviews happen in one
//! place. Localization, when it lands, swaps the struct.

pub const missing_api_key_prefix = "tigerclaw: missing API key for provider '";
pub const missing_api_key_suffix = "'. Set the matching environment variable.";
pub const unsupported_provider = "tigerclaw: provider is not supported in this build.";
pub const budget_exhausted = "tigerclaw: cost budget exhausted. Increase the budget or end the session.";
pub const bench_forbidden_tool = "tigerclaw: tool is not allowed in bench mode.";

// --- tests -----------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "messages: every constant is non-empty and ASCII-safe" {
    inline for (comptime std.meta.declarations(@This())) |decl| {
        // Skip the private `testing` alias by type-checking.
        const val = @field(@This(), decl.name);
        const T = @TypeOf(val);
        if (T == []const u8 or comptime std.mem.startsWith(u8, @typeName(T), "*const [")) {
            const s: []const u8 = val;
            try testing.expect(s.len > 0);
            for (s) |b| try testing.expect(b >= 0x20 and b <= 0x7E);
        }
    }
}
