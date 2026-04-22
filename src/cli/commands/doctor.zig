//! `tigerclaw doctor` — print a short environment summary.
//!
//! The doctor verb is intentionally boring: it reports what the runtime
//! can see so operators can sanity-check an install without running any
//! real command. It writes to a caller-provided writer and pulls every
//! input from an explicit `Inputs` struct so tests stay pure.
//!
//! This commit covers the printable surface only. A future commit wires
//! it to the descriptor dispatcher and `std.process.getEnvVarOwned` to
//! populate `Inputs` from the real environment.

const std = @import("std");
const managed_path = @import("../../settings/managed_path.zig");
const version = @import("../../version.zig");

pub const Inputs = struct {
    zig_version: []const u8,
    os_tag: []const u8,
    arch_tag: []const u8,
    env_xdg: ?[]const u8 = null,
    env_home: ?[]const u8 = null,
    env_config: ?[]const u8 = null,
};

pub fn writeReport(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    inputs: Inputs,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    try w.print("tigerclaw {s}\n", .{version.string});
    try w.print("  zig     {s}\n", .{inputs.zig_version});
    try w.print("  os      {s}\n", .{inputs.os_tag});
    try w.print("  arch    {s}\n", .{inputs.arch_tag});

    // Config path resolution does not touch the filesystem; it just
    // composes the path the runtime *would* read.
    const resolved = managed_path.resolve(allocator, .{
        .env_config = inputs.env_config,
        .env_xdg = inputs.env_xdg,
        .env_home = inputs.env_home,
    }) catch |err| switch (err) {
        error.NoCandidate => {
            try w.writeAll("  config  <unresolved: neither TIGERCLAW_CONFIG, XDG_CONFIG_HOME, nor HOME is set>\n");
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer resolved.deinit(allocator);

    const source_label = switch (resolved.source) {
        .flag => "flag",
        .env => "env",
        .xdg => "xdg",
        .home => "home",
    };
    try w.print("  config  {s} ({s})\n", .{ resolved.path, source_label });
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeReport: prints runtime version, zig version, os, arch" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(testing.allocator, &w, .{
        .zig_version = "0.16.0",
        .os_tag = "macos",
        .arch_tag = "aarch64",
        .env_home = "/home/u",
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "tigerclaw ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig     0.16.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "os      macos") != null);
    try testing.expect(std.mem.indexOf(u8, out, "arch    aarch64") != null);
}

test "writeReport: reports the resolved config path and its source" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(testing.allocator, &w, .{
        .zig_version = "0.16.0",
        .os_tag = "linux",
        .arch_tag = "x86_64",
        .env_xdg = "/xdg",
        .env_home = "/home/u",
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "/xdg/tigerclaw/config.jsonc (xdg)") != null);
}

test "writeReport: emits <unresolved> when no path hint is available" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(testing.allocator, &w, .{
        .zig_version = "0.16.0",
        .os_tag = "linux",
        .arch_tag = "x86_64",
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "<unresolved") != null);
}
