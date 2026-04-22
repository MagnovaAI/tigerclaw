//! Top-level harness.
//!
//! The `Harness` is the process-scoped owner of everything a running
//! conversation needs: the allocator, the injected clock, the `Io`
//! handle for filesystem work, and the directory where session state
//! lives. It is the single entry point used by the CLI
//! (`tigerclaw run`, `tigerclaw run --resume <id>`) and by higher-
//! level agent code in later phases.
//!
//! Scope for this commit: session lifecycle only (create / resume /
//! save). The react loop, budget, permissions, sandbox, and cost
//! ledger land in follow-up commits and plug into this surface via
//! the `Options` struct and the `Session` value rather than by
//! rewriting the harness.
//!
//! The `--resume` flag is a CLI-level concern; this module exposes the
//! underlying `resumeSession(id)` call that the flag handler invokes.

const std = @import("std");
const Io = std.Io;
const clock_mod = @import("../clock.zig");
const session_mod = @import("session.zig");

pub const Session = session_mod.Session;

/// Construction inputs for a `Harness`. Bundled in a struct so future
/// knobs (budget, permissions, determinism seed, …) can be added
/// without touching every call site.
pub const Options = struct {
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    io: Io,
    /// Directory that holds `<session-id>.json` files. Caller retains
    /// ownership; must outlive the harness.
    state_dir: Io.Dir,
};

pub const Harness = struct {
    allocator: std.mem.Allocator,
    clock: clock_mod.Clock,
    io: Io,
    state_dir: Io.Dir,

    pub fn init(opts: Options) Harness {
        return .{
            .allocator = opts.allocator,
            .clock = opts.clock,
            .io = opts.io,
            .state_dir = opts.state_dir,
        };
    }

    /// Start a new session with the caller-supplied id. The id is
    /// expected to be stable under replay (derived from the
    /// determinism seed); this module does not generate ids itself so
    /// the source of randomness remains in one place.
    pub fn startSession(self: *Harness, id: []const u8) !Session {
        return Session.start(self.allocator, self.clock, id);
    }

    /// Reload the session previously persisted under `id`. Backs
    /// `tigerclaw run --resume <id>`.
    pub fn resumeSession(self: *Harness, id: []const u8) !Session {
        const file_name = try sessionFileName(self.allocator, id);
        defer self.allocator.free(file_name);

        const buf = try self.allocator.alloc(u8, max_session_bytes);
        defer self.allocator.free(buf);

        const bytes = try self.state_dir.readFile(self.io, file_name, buf);
        return Session.resumeFromBytes(self.allocator, self.clock, bytes);
    }

    /// Persist a session under its id. Safe to call repeatedly; each
    /// call performs an atomic tmp-rename of the session file.
    pub fn saveSession(self: *Harness, session: *const Session) !void {
        const file_name = try sessionFileName(self.allocator, session.id());
        defer self.allocator.free(file_name);
        try session.save(self.state_dir, self.io, file_name);
    }
};

/// Upper bound on the size of a session file we are willing to load.
/// Sessions grow with conversation length; 16 MiB is generous for
/// text-only histories and bounded enough to catch corruption loops.
pub const max_session_bytes: usize = 16 * 1024 * 1024;

/// Canonical on-disk filename for a session id.
pub fn sessionFileName(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.json", .{id});
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "sessionFileName formats id with .json suffix" {
    const name = try sessionFileName(testing.allocator, "abc123");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("abc123.json", name);
}

test "Harness: start + save + resume roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{ .value_ns = 1 };
    var h = Harness.init(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
    });

    var s = try h.startSession("abc");
    defer s.deinit();
    try s.appendTurn("hi", "hello");
    try h.saveSession(&s);

    var resumed = try h.resumeSession("abc");
    defer resumed.deinit();
    try testing.expectEqualStrings("abc", resumed.id());
    try testing.expectEqual(@as(u32, 1), resumed.turnCount());
    try testing.expectEqualStrings("hello", resumed.turns.items[0].assistant.content);
}

test "Harness: resume of unknown id surfaces the filesystem error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mc = clock_mod.ManualClock{};
    var h = Harness.init(.{
        .allocator = testing.allocator,
        .clock = mc.clock(),
        .io = testing.io,
        .state_dir = tmp.dir,
    });

    try testing.expectError(error.FileNotFound, h.resumeSession("missing"));
}
