//! Session router: maps a (channel_id, conversation_key, thread_key)
//! tuple to the on-disk path of the session JSON for that conversation.
//!
//! The router is the trust boundary for keys that originate from
//! external services — once a key passes `isUrlSafeKey` it is
//! interpolated directly into a filesystem path, so the whitelist is
//! tight on purpose: `[A-Za-z0-9_-]`, nothing else. Reject at this
//! layer and the dispatch path can assume every key is safe.
//!
//! Layout: `<channel_id>/<conversation_key>[--<thread_key>]/state.json`
//! relative to the state root. Callers combine the returned slice with
//! the stored `std.Io.Dir` to open or create the file.

const std = @import("std");
const spec = @import("channels_spec");

pub const Router = struct {
    /// Root directory for session state on disk. Paths returned by
    /// `resolve` are relative to this directory.
    state_root: std.Io.Dir,

    pub fn init(state_root: std.Io.Dir) Router {
        return .{ .state_root = state_root };
    }

    pub const ResolveError = error{
        /// A key contained a character outside `[A-Za-z0-9_-]`, or was
        /// empty. The dispatch layer must drop the message.
        InvalidKey,
        /// The composed path does not fit in the caller-supplied
        /// buffer. Callers grow the buffer and retry, or drop.
        PathTooLong,
    };

    /// Build the on-disk path for a session. The returned slice aliases
    /// `out_buf`. The path is relative to `state_root`.
    pub fn resolve(
        self: Router,
        out_buf: []u8,
        channel_id: spec.ChannelId,
        conversation_key: []const u8,
        thread_key: ?[]const u8,
    ) ResolveError![]const u8 {
        _ = self;

        if (!isUrlSafeKey(conversation_key)) return ResolveError.InvalidKey;
        if (thread_key) |tk| {
            if (!isUrlSafeKey(tk)) return ResolveError.InvalidKey;
        }

        const kind = @tagName(channel_id);

        var w: std.Io.Writer = .fixed(out_buf);
        w.writeAll(kind) catch return ResolveError.PathTooLong;
        w.writeByte('/') catch return ResolveError.PathTooLong;
        w.writeAll(conversation_key) catch return ResolveError.PathTooLong;
        if (thread_key) |tk| {
            w.writeAll("--") catch return ResolveError.PathTooLong;
            w.writeAll(tk) catch return ResolveError.PathTooLong;
        }
        w.writeAll("/state.json") catch return ResolveError.PathTooLong;

        return w.buffered();
    }
};

/// URL-safe characters: `[A-Za-z0-9_-]`. No slashes, no dots, no spaces,
/// no empty strings. This is the trust boundary — every downstream path
/// operation trusts that keys passing this check are safe to interpolate.
pub fn isUrlSafeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn tmpRouter(tmp: *std.testing.TmpDir) Router {
    return Router.init(tmp.dir);
}

test "resolve: no thread key produces <channel>/<key>/state.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = tmpRouter(&tmp);

    var buf: [256]u8 = undefined;
    const path = try r.resolve(&buf, .telegram, "123", null);
    try testing.expectEqualStrings("telegram/123/state.json", path);
}

test "resolve: thread key is appended with `--` separator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = tmpRouter(&tmp);

    var buf: [256]u8 = undefined;
    const path = try r.resolve(&buf, .telegram, "123", "topic-7");
    try testing.expectEqualStrings("telegram/123--topic-7/state.json", path);
}

test "resolve: rejects traversal in conversation_key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = tmpRouter(&tmp);

    var buf: [256]u8 = undefined;
    try testing.expectError(
        Router.ResolveError.InvalidKey,
        r.resolve(&buf, .telegram, "../escape", null),
    );
}

test "resolve: rejects traversal in thread_key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = tmpRouter(&tmp);

    var buf: [256]u8 = undefined;
    try testing.expectError(
        Router.ResolveError.InvalidKey,
        r.resolve(&buf, .telegram, "ok", "../bad"),
    );
}

test "resolve: returns PathTooLong when the buffer is too small" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = tmpRouter(&tmp);

    var buf: [8]u8 = undefined;
    try testing.expectError(
        Router.ResolveError.PathTooLong,
        r.resolve(&buf, .telegram, "a-long-enough-key", null),
    );
}

test "isUrlSafeKey: accepts alphanumerics, dash, underscore" {
    try testing.expect(isUrlSafeKey("abc"));
    try testing.expect(isUrlSafeKey("ABC123"));
    try testing.expect(isUrlSafeKey("a-b_c"));
    try testing.expect(isUrlSafeKey("0"));
}

test "isUrlSafeKey: rejects structural and empty keys" {
    try testing.expect(!isUrlSafeKey(""));
    try testing.expect(!isUrlSafeKey("a/b"));
    try testing.expect(!isUrlSafeKey("a.b"));
    try testing.expect(!isUrlSafeKey("a b"));
    try testing.expect(!isUrlSafeKey(".."));
}
