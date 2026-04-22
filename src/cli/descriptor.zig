//! Descriptor-driven command dispatcher.
//!
//! A `CommandDescriptor` names a top-level verb (e.g. `version`, `help`,
//! `gateway`), a short one-line summary used in generated help output,
//! and a `handler` function pointer that concrete command modules own.
//!
//! The dispatcher itself stays behavior-free: it matches argv[0] against
//! the registered descriptor table and returns a typed `Match`. The
//! caller is responsible for invoking the handler (or, as today, for
//! translating `Match` into the legacy `Command` union while individual
//! verbs are ported onto the new surface).

const std = @import("std");

pub const HandlerError = error{
    UsageError,
    RuntimeError,
};

/// Signature of a command handler.
///
/// Handlers receive argv *including* their own verb as argv[0] so they
/// can implement their own local flag parsing without needing to know
/// how the dispatcher stripped leading arguments.
pub const Handler = *const fn (argv: []const []const u8) HandlerError!void;

pub const CommandDescriptor = struct {
    name: []const u8,
    summary: []const u8,
    handler: ?Handler = null,
};

pub const Match = struct {
    descriptor: *const CommandDescriptor,
    /// argv positions owned by this command (`argv[0]` is the verb).
    argv: []const []const u8,
};

pub const DispatchError = error{
    MissingCommand,
    UnknownCommand,
};

/// Resolve `argv` against `table`. `argv` must not include the program
/// name. Returns either a `Match` pointing into `table` + the original
/// argv slice, or a dispatch error.
pub fn resolve(
    table: []const CommandDescriptor,
    argv: []const []const u8,
) DispatchError!Match {
    if (argv.len == 0) return error.MissingCommand;

    const first = argv[0];
    for (table) |*entry| {
        if (std.mem.eql(u8, entry.name, first)) {
            return .{ .descriptor = entry, .argv = argv };
        }
    }
    return error.UnknownCommand;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn noopHandler(_: []const []const u8) HandlerError!void {}

test "resolve: matches the first descriptor by name" {
    const table = [_]CommandDescriptor{
        .{ .name = "gateway", .summary = "manage the gateway", .handler = noopHandler },
        .{ .name = "agent", .summary = "chat with an agent", .handler = noopHandler },
    };
    const argv = [_][]const u8{ "agent", "-m", "hi" };
    const m = try resolve(&table, &argv);
    try testing.expectEqualStrings("agent", m.descriptor.name);
    try testing.expectEqual(@as(usize, 3), m.argv.len);
    try testing.expectEqualStrings("agent", m.argv[0]);
}

test "resolve: empty argv returns MissingCommand" {
    const table = [_]CommandDescriptor{.{ .name = "x", .summary = "", .handler = noopHandler }};
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingCommand, resolve(&table, &argv));
}

test "resolve: unknown verb returns UnknownCommand" {
    const table = [_]CommandDescriptor{.{ .name = "gateway", .summary = "", .handler = noopHandler }};
    const argv = [_][]const u8{"nope"};
    try testing.expectError(error.UnknownCommand, resolve(&table, &argv));
}

test "resolve: descriptors may be handler-less (summary-only placeholders)" {
    const table = [_]CommandDescriptor{.{ .name = "todo", .summary = "reserved" }};
    const argv = [_][]const u8{"todo"};
    const m = try resolve(&table, &argv);
    try testing.expect(m.descriptor.handler == null);
}
