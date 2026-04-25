//! ANSI escape helpers — OSC 8 hyperlinks and a tiny ANSI-stripper.
//!
//! OSC 8 path-link strategy: inline escapes.
//! (Phase 0 decision; vaxis 0.x's `Cell.Hyperlink` attribute is also
//! available but inline is simpler when we're rendering into plain
//! text buffers shared with the gateway's SSE path. If a future TUI
//! pass moves to per-cell attribute rendering, replace `writePathLink`
//! with a vaxis-aware variant; the inline form is the fallback.)

const std = @import("std");

/// Set at startup based on terminal capabilities. The default is
/// conservative: emit plain text unless the host opts in. The TUI's
/// startup path flips this when the connected terminal advertises
/// hyperlinks (vaxis provides the cap probe).
pub var hyperlinks_supported: bool = false;

/// Append a clickable path link to `buf`. When hyperlinks aren't
/// available we just append `rel_path` as plain text — the rendering
/// stays intelligible and there's no garbage escape leakage on
/// terminals that don't speak OSC 8.
pub fn writePathLink(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    rel_path: []const u8,
) !void {
    if (!hyperlinks_supported) {
        try buf.appendSlice(allocator, rel_path);
        return;
    }

    const abs = try std.fs.path.join(allocator, &.{ workspace_root, rel_path });
    defer allocator.free(abs);

    // OSC 8 open: ESC ] 8 ; ; file://<abs> ESC \
    try buf.appendSlice(allocator, "\x1b]8;;file://");
    try buf.appendSlice(allocator, abs);
    try buf.appendSlice(allocator, "\x1b\\");
    // Display text.
    try buf.appendSlice(allocator, rel_path);
    // OSC 8 close: ESC ] 8 ; ; ESC \
    try buf.appendSlice(allocator, "\x1b]8;;\x1b\\");
}

/// Strip CSI / OSC escape sequences from `s`. Used when feeding tool
/// output through the generic preview path; keeps the generic
/// renderer (which is plain-text) from showing literal escapes.
pub fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len) {
            const next = s[i + 1];
            if (next == '[') {
                // CSI: ESC [ ... <final byte 0x40-0x7E>
                i += 2;
                while (i < s.len) : (i += 1) {
                    const c = s[i];
                    if (c >= 0x40 and c <= 0x7E) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (next == ']') {
                // OSC: ESC ] ... ST (ESC \ or BEL).
                i += 2;
                while (i < s.len) : (i += 1) {
                    if (s[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            // Unknown ESC sequence: drop ESC + next.
            i += 2;
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writePathLink: plain text when unsupported" {
    hyperlinks_supported = false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writePathLink(&buf, testing.allocator, "/tmp", "foo.txt");
    try testing.expectEqualStrings("foo.txt", buf.items);
}

test "writePathLink: emits OSC 8 when supported" {
    hyperlinks_supported = true;
    defer hyperlinks_supported = false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writePathLink(&buf, testing.allocator, "/tmp", "foo.txt");
    try testing.expect(std.mem.indexOf(u8, buf.items, "\x1b]8;;file:///tmp/foo.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "foo.txt\x1b]8;;\x1b\\") != null);
}

test "stripAnsi: removes CSI color codes" {
    const out = try stripAnsi(testing.allocator, "\x1b[31mred\x1b[0m text");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("red text", out);
}

test "stripAnsi: removes OSC sequences" {
    const out = try stripAnsi(testing.allocator, "before\x1b]0;title\x07after");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("beforeafter", out);
}

test "stripAnsi: passthrough for plain text" {
    const out = try stripAnsi(testing.allocator, "hello world\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world\n", out);
}
