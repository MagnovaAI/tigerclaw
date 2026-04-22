//! Presentation helpers for CLI output.
//!
//! Centralises banner text, simple ANSI colour helpers, and a minimal
//! two-column table formatter used for generated help output. All
//! helpers write into a caller-provided `std.Io.Writer` so tests can
//! capture output without touching real stdout.
//!
//! Colour is opt-in at the call site. The intent is that higher layers
//! decide based on `std.fs.File.isTty()` and env vars (e.g. `NO_COLOR`);
//! this module stays pure so unit tests remain deterministic.

const std = @import("std");

pub const banner =
    \\tigerclaw — agent runtime
;

pub const Color = enum {
    dim,
    bold,
    none,

    pub fn open(self: Color) []const u8 {
        return switch (self) {
            .dim => "\x1b[2m",
            .bold => "\x1b[1m",
            .none => "",
        };
    }

    pub fn close(self: Color) []const u8 {
        return switch (self) {
            .dim, .bold => "\x1b[0m",
            .none => "",
        };
    }
};

pub fn writeBanner(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{s}\n", .{banner});
}

/// Render a two-column aligned table of `(name, summary)` rows. The
/// first column is padded to `min_name_width` or to the widest name
/// (whichever is larger) plus two spaces of gutter. No colour is
/// applied.
pub fn writeTable(
    w: *std.Io.Writer,
    comptime Row: type,
    rows: []const Row,
    min_name_width: usize,
) std.Io.Writer.Error!void {
    var widest: usize = min_name_width;
    for (rows) |row| {
        if (row.name.len > widest) widest = row.name.len;
    }

    for (rows) |row| {
        try w.print("  {s}", .{row.name});
        const pad = widest + 2 - row.name.len;
        var i: usize = 0;
        while (i < pad) : (i += 1) try w.writeByte(' ');
        try w.print("{s}\n", .{row.summary});
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeBanner writes the banner followed by a newline" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    const out = w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "tigerclaw — agent runtime"));
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "writeTable: aligns columns by the widest name" {
    const Row = struct { name: []const u8, summary: []const u8 };
    const rows = [_]Row{
        .{ .name = "a", .summary = "short" },
        .{ .name = "gateway", .summary = "longer" },
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTable(&w, Row, &rows, 0);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "  a        short") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  gateway  longer") != null);
}

test "writeTable: respects min_name_width when rows are narrow" {
    const Row = struct { name: []const u8, summary: []const u8 };
    const rows = [_]Row{.{ .name = "x", .summary = "y" }};
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTable(&w, Row, &rows, 10);
    const out = w.buffered();
    // "  x" + 11 spaces (10 + 2 gutter - 1 for 'x') + "y" + "\n"
    try testing.expect(std.mem.indexOf(u8, out, "  x           y\n") != null);
}

test "Color.open/close: emits ANSI codes for dim and bold, empty for none" {
    try testing.expectEqualStrings("\x1b[2m", Color.dim.open());
    try testing.expectEqualStrings("\x1b[0m", Color.dim.close());
    try testing.expectEqualStrings("\x1b[1m", Color.bold.open());
    try testing.expectEqualStrings("\x1b[0m", Color.bold.close());
    try testing.expectEqualStrings("", Color.none.open());
    try testing.expectEqualStrings("", Color.none.close());
}
