//! Cassette file format.
//!
//! A cassette is a JSON-lines file. The first line is a `Header`; every
//! subsequent line is an `Interaction` (one HTTP request + its response).
//! JSON over YAML is a deliberate choice — Zig has no std YAML, the
//! recorder's only reader is tigerclaw itself, and JSON-lines is what
//! the trace subsystem already speaks.

const std = @import("std");

pub const format_version: u16 = 1;

pub const Header = struct {
    format_version: u16 = format_version,
    cassette_id: []const u8,
    created_at_ns: i128,
};

pub const Request = struct {
    method: []const u8,
    url: []const u8,
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const Interaction = struct {
    request: Request,
    response: Response,
};

pub const FormatError = error{
    UnsupportedFormat,
};

pub fn checkFormat(header: Header) FormatError!void {
    if (header.format_version != format_version) return error.UnsupportedFormat;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "format_version is pinned" {
    try testing.expectEqual(@as(u16, 1), format_version);
}

test "Header: JSON roundtrip preserves every field" {
    const h = Header{
        .cassette_id = "c-1",
        .created_at_ns = 1_700_000_000_000_000_000,
    };
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, h, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Header, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(format_version, parsed.value.format_version);
    try testing.expectEqualStrings("c-1", parsed.value.cassette_id);
    try testing.expectEqual(h.created_at_ns, parsed.value.created_at_ns);
}

test "Interaction: JSON roundtrip preserves request + response" {
    const i = Interaction{
        .request = .{ .method = "POST", .url = "https://x.test/v1", .body = "{\"q\":1}" },
        .response = .{ .status = 200, .body = "{\"ok\":true}" },
    };
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, i, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Interaction, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("POST", parsed.value.request.method);
    try testing.expectEqualStrings("https://x.test/v1", parsed.value.request.url);
    try testing.expectEqualStrings("{\"q\":1}", parsed.value.request.body.?);
    try testing.expectEqual(@as(u16, 200), parsed.value.response.status);
    try testing.expectEqualStrings("{\"ok\":true}", parsed.value.response.body);
}

test "checkFormat: foreign version rejected" {
    const h = Header{ .format_version = 99, .cassette_id = "x", .created_at_ns = 0 };
    try testing.expectError(error.UnsupportedFormat, checkFormat(h));
}
