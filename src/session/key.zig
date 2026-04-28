//! Session identity helpers.
//!
//! A logical session is identified by `(conversation_id, agent_name)`. Today
//! the TUI runs a single conversation, so `conversation_id` is hardcoded to
//! `"default"` at the call sites — but every persistence/routing surface that
//! takes a session goes through this module. That keeps the day we add real
//! conversation ids from being a refactor across two dozen files.
//!
//! Two distinct functions because logical identity and filesystem paths have
//! different safety requirements:
//!
//!   - `make` returns the logical key `<conversation>/<agent>`. Raw values,
//!     used for routing / lookups / log line tags. Never written to disk
//!     directly.
//!
//!   - `appendPath` builds a filesystem path under a root directory, encoding
//!     each segment so untrusted ids cannot escape the directory or collide
//!     after sanitization (`foo/bar` and `foo_bar` would otherwise collapse).
//!     Encoding strategy: percent-encode any byte that is not in the safe
//!     set `[A-Za-z0-9._-]`. Long segments are truncated and suffixed with
//!     a short hash to keep filesystem limits without losing identity.

const std = @import("std");

/// Logical session key: `<conversation_id>/<agent_name>`. Caller owns the
/// returned slice. Used as a routing handle and a log tag — never as a path.
pub fn make(
    allocator: std.mem.Allocator,
    conversation_id: []const u8,
    agent_name: []const u8,
) ![]u8 {
    if (conversation_id.len == 0) return error.EmptyConversationId;
    if (agent_name.len == 0) return error.EmptyAgentName;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ conversation_id, agent_name });
}

/// Build a path `<root>/<enc(conversation)>/<enc(agent)>/<filename>`. The
/// conversation and agent segments are percent-encoded so that distinct
/// logical ids never collapse to the same path. `filename` is appended
/// verbatim — callers pass fixed names like `"chat.session.jsonl"`.
///
/// Long segments (≥ `segment_truncate_at` bytes) are shortened and tagged
/// with a 16-hex-char SHA-256 prefix so they fit common filesystem limits
/// (255 bytes) while still being collision-resistant.
pub fn appendPath(
    allocator: std.mem.Allocator,
    root: []const u8,
    conversation_id: []const u8,
    agent_name: []const u8,
    filename: []const u8,
) ![]u8 {
    if (conversation_id.len == 0) return error.EmptyConversationId;
    if (agent_name.len == 0) return error.EmptyAgentName;
    // Reject literal "." / ".." segments before encoding — these would
    // round-trip through `isSafe` unchanged and create directory-traversal
    // paths even though every byte is "safe".
    if (isDotSegment(conversation_id) or isDotSegment(agent_name)) {
        return error.ReservedSegment;
    }

    const conv_seg = try encodeSegment(allocator, conversation_id);
    defer allocator.free(conv_seg);
    const agent_seg = try encodeSegment(allocator, agent_name);
    defer allocator.free(agent_seg);

    return std.fs.path.join(allocator, &.{ root, conv_seg, agent_seg, filename });
}

/// Maximum bytes before a segment is hashed-and-truncated. 200 leaves room
/// for the parent path + filename within typical 255-byte path limits.
const segment_truncate_at: usize = 200;

/// Percent-encode a segment so the result is filesystem-safe and round-trips
/// distinct inputs to distinct outputs (no silent collapses).
fn encodeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (segment) |c| {
        if (isSafe(c)) {
            try buf.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[(c >> 4) & 0xF]);
            try buf.append(allocator, hex[c & 0xF]);
        }
    }

    if (buf.items.len <= segment_truncate_at) return buf.toOwnedSlice(allocator);

    // Long segment: keep a readable prefix, append SHA-256-derived tag so two
    // long ids that share a prefix don't collide.
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(segment, &hash, .{});
    var hex: [16]u8 = undefined;
    const lower = "0123456789abcdef";
    for (hash[0..8], 0..) |b, i| {
        hex[i * 2] = lower[(b >> 4) & 0xF];
        hex[i * 2 + 1] = lower[b & 0xF];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, buf.items[0 .. segment_truncate_at - 17]);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, &hex);
    buf.deinit(allocator);
    return out.toOwnedSlice(allocator);
}

fn isDotSegment(s: []const u8) bool {
    return std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..");
}

fn isSafe(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '-' or c == '_';
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "make: simple values" {
    const k = try make(testing.allocator, "default", "tiger");
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("default/tiger", k);
}

test "make: empty conversation rejected" {
    try testing.expectError(error.EmptyConversationId, make(testing.allocator, "", "tiger"));
}

test "make: empty agent rejected" {
    try testing.expectError(error.EmptyAgentName, make(testing.allocator, "default", ""));
}

test "appendPath: safe segments stay readable" {
    const p = try appendPath(testing.allocator, "/root", "default", "tiger", "chat.jsonl");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/root/default/tiger/chat.jsonl", p);
}

test "appendPath: slash in id encoded, not silently collapsed" {
    const a = try appendPath(testing.allocator, "/r", "foo/bar", "x", "f");
    defer testing.allocator.free(a);
    const b = try appendPath(testing.allocator, "/r", "foo_bar", "x", "f");
    defer testing.allocator.free(b);
    // foo/bar → foo%2Fbar; foo_bar → foo_bar. Distinct ids stay distinct.
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.indexOf(u8, a, "foo%2Fbar") != null);
}

test "appendPath: dotdot rejected" {
    try testing.expectError(
        error.ReservedSegment,
        appendPath(testing.allocator, "/r", "..", "x", "f"),
    );
    try testing.expectError(
        error.ReservedSegment,
        appendPath(testing.allocator, "/r", "x", ".", "f"),
    );
}

test "appendPath: nul byte encoded" {
    const id = [_]u8{ 'a', 0, 'b' };
    const p = try appendPath(testing.allocator, "/r", &id, "x", "f");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "%00") != null);
}

test "appendPath: long segments collide-resistant after truncation" {
    var long_a: [400]u8 = undefined;
    var long_b: [400]u8 = undefined;
    @memset(&long_a, 'a');
    @memset(&long_b, 'a');
    long_b[399] = 'b'; // differs only in the last byte

    const a = try appendPath(testing.allocator, "/r", &long_a, "x", "f");
    defer testing.allocator.free(a);
    const b = try appendPath(testing.allocator, "/r", &long_b, "x", "f");
    defer testing.allocator.free(b);

    try testing.expect(!std.mem.eql(u8, a, b));
    // Both should be bounded in length so they fit on disk.
    try testing.expect(a.len < 300);
    try testing.expect(b.len < 300);
}

test "appendPath: empty conversation rejected" {
    try testing.expectError(
        error.EmptyConversationId,
        appendPath(testing.allocator, "/r", "", "x", "f"),
    );
}
