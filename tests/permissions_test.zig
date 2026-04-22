//! Integration tests for the permissions subsystem.
//!
//! These drive the full flow (policy → evaluate → store → prompt)
//! through the public `Permissions` facade with a scripted
//! `Responder`. The runtime's confidence in "ask the user, then
//! remember" lives or dies by these checks.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const permissions = tigerclaw.permissions;

/// Scripted responder that plays a queue of responses.
const ScriptedResponder = struct {
    queue: []const permissions.Response,
    cursor: usize = 0,
    prompts_observed: usize = 0,

    fn ask(ptr: *anyopaque, p: permissions.Prompt) anyerror!permissions.Response {
        _ = p;
        const self: *ScriptedResponder = @ptrCast(@alignCast(ptr));
        self.prompts_observed += 1;
        if (self.cursor >= self.queue.len) return error.ScriptExhausted;
        const r = self.queue[self.cursor];
        self.cursor += 1;
        return r;
    }
    fn responder(self: *ScriptedResponder) permissions.Responder {
        return .{ .ptr = self, .vtable = &.{ .ask = ask } };
    }
};

test "permissions: supervised session — prompt once, cache session scope" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();
    const script = [_]permissions.Response{permissions.Response.allowSession()};
    var sr = ScriptedResponder{ .queue = &script };
    var perms = permissions.Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        sr.responder(),
    );

    // First write: prompt, user allows for session.
    const o1 = try perms.check(.{ .kind = .fs_write, .target = "/work/main.zig" });
    try testing.expect(o1.approved);
    try testing.expect(o1.prompted);

    // Second write to same target: cached, no prompt.
    const o2 = try perms.check(.{ .kind = .fs_write, .target = "/work/main.zig" });
    try testing.expect(o2.approved);
    try testing.expect(!o2.prompted);

    // Third write to a different target: prompts again. Script is
    // exhausted — surfaces the error so we know we did try to
    // prompt (rather than silently reusing the cache).
    try testing.expectError(
        error.ScriptExhausted,
        perms.check(.{ .kind = .fs_write, .target = "/work/other.zig" }),
    );
    try testing.expectEqual(@as(usize, 2), sr.prompts_observed);
}

test "permissions: read_only refuses exec without prompting" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();
    var sr = ScriptedResponder{ .queue = &.{} };
    var perms = permissions.Permissions.init(
        .{ .autonomy = .read_only },
        &store,
        sr.responder(),
    );

    const o = try perms.check(.{ .kind = .exec, .target = "/bin/ls" });
    try testing.expect(!o.approved);
    try testing.expect(!o.prompted);
    try testing.expectEqual(@as(usize, 0), sr.prompts_observed);
}

test "permissions: cached denial persists across calls" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();
    const script = [_]permissions.Response{
        .{ .approved = false, .remember = .session },
    };
    var sr = ScriptedResponder{ .queue = &script };
    var perms = permissions.Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        sr.responder(),
    );

    const first = try perms.check(.{ .kind = .exec, .target = "/bin/rm" });
    try testing.expect(!first.approved);
    try testing.expect(first.prompted);

    const second = try perms.check(.{ .kind = .exec, .target = "/bin/rm" });
    try testing.expect(!second.approved);
    try testing.expect(!second.prompted);
    try testing.expectEqual(@as(usize, 1), sr.prompts_observed);
}

test "permissions: override cannot loosen stricter default" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();
    var sr = ScriptedResponder{ .queue = &.{} };

    // Attempt to bypass `read_only`'s exec=never by overriding it
    // to `always`. `stricter` wins — the action still denies.
    var perms = permissions.Permissions.init(
        .{ .autonomy = .read_only, .overrides = .{ .exec = .always } },
        &store,
        sr.responder(),
    );

    const o = try perms.check(.{ .kind = .exec, .target = "/bin/ls" });
    try testing.expect(!o.approved);
    try testing.expect(!o.prompted);
}

test "permissions: full autonomy still prompts for unclassified tool_call" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();
    const script = [_]permissions.Response{permissions.Response.allowOnce()};
    var sr = ScriptedResponder{ .queue = &script };
    var perms = permissions.Permissions.init(
        .{ .autonomy = .full },
        &store,
        sr.responder(),
    );

    const o = try perms.check(.{ .kind = .tool_call, .target = "mystery_tool" });
    try testing.expect(o.approved);
    try testing.expect(o.prompted);
}

test "permissions: mixed workload — fs_read free, fs_write gated, exec prompts each time when once" {
    var store = permissions.Store.init(testing.allocator);
    defer store.deinit();

    const script = [_]permissions.Response{
        permissions.Response.allowOnce(), // first fs_write
        permissions.Response.allowOnce(), // second fs_write, same target (should re-ask, `once`)
        permissions.Response.allowSession(), // exec /bin/git
    };
    var sr = ScriptedResponder{ .queue = &script };
    var perms = permissions.Permissions.init(
        .{ .autonomy = .supervised },
        &store,
        sr.responder(),
    );

    // fs_read: allow, no prompt.
    const r1 = try perms.check(.{ .kind = .fs_read, .target = "/x" });
    try testing.expect(r1.approved);
    try testing.expect(!r1.prompted);

    // fs_write x2, both once-scoped → both prompt.
    _ = try perms.check(.{ .kind = .fs_write, .target = "/x" });
    _ = try perms.check(.{ .kind = .fs_write, .target = "/x" });

    // exec, session-scoped → prompts first, caches second.
    const e1 = try perms.check(.{ .kind = .exec, .target = "/bin/git" });
    try testing.expect(e1.prompted);
    const e2 = try perms.check(.{ .kind = .exec, .target = "/bin/git" });
    try testing.expect(!e2.prompted);

    try testing.expectEqual(@as(usize, 3), sr.prompts_observed);
}
