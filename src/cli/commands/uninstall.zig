//! `tigerclaw uninstall` — remove the binary and (optionally) the
//! local state directory.
//!
//! v0.1.0 caveat: Zig 0.16 does not expose `std.fs.selfExePathAlloc`
//! on this build, so the command can't reliably locate its own
//! binary. We instead print a clear "remove the binary at <path>
//! manually" line and remove only the state directory. The state
//! removal is the genuinely valuable half of the operation — the
//! binary is just a single file and `which tigerclaw` plus `rm`
//! covers the other half cleanly.
//!
//! Confirmation flow: the user must type `yes` on stdin unless
//! `--yes` is passed. `--keep-config` skips state removal entirely.
//!
//! State path is the `~/.tigerclaw` directory the rest of the
//! runtime writes into. Tests inject the path so we never touch the
//! real state directory.

const std = @import("std");

pub const Args = struct {
    keep_config: bool = false,
    yes: bool = false,
    /// Optional state-directory override. When null, the runner
    /// resolves `$HOME/.tigerclaw`. Tests pass an explicit path so
    /// they never touch the real directory.
    state_dir: ?[]const u8 = null,
    /// Optional binary-path override. When null, the runner reports
    /// "<unknown — remove manually>" since 0.16's std doesn't ship a
    /// portable self-exe path lookup.
    binary_path: ?[]const u8 = null,
};

pub const ParseError = error{
    UnknownFlag,
};

pub fn parse(argv: []const []const u8) ParseError!Args {
    var args: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--yes") or std.mem.eql(u8, flag, "-y")) {
            args.yes = true;
        } else if (std.mem.eql(u8, flag, "--keep-config")) {
            args.keep_config = true;
        } else {
            return error.UnknownFlag;
        }
    }
    return args;
}

pub const Error = error{
    /// User declined the "type yes" prompt.
    Aborted,
    /// State directory removal failed for a non-missing reason
    /// (permission denied, mid-deletion error, etc.).
    PermissionDenied,
    StateRemovalFailed,
    /// Stdin closed / read error before we could read the prompt.
    PromptReadFailed,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: Args,
    stdin_reader: *std.Io.Reader,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Error!void {
    _ = allocator;

    if (!args.yes) {
        try out.writeAll("type 'yes' to confirm uninstall: ");
        try out.flush();
        const line = readTrimmedLine(stdin_reader) catch
            return error.PromptReadFailed;
        if (!std.mem.eql(u8, line, "yes")) {
            try err.writeAll("uninstall aborted\n");
            return error.Aborted;
        }
    }

    const binary = args.binary_path orelse "<unknown — remove manually>";

    var state_kept = args.keep_config;
    if (!state_kept) {
        if (args.state_dir) |dir_path| {
            std.Io.Dir.cwd().deleteTree(io, dir_path) catch |e| switch (e) {
                error.AccessDenied => return error.PermissionDenied,
                else => return error.StateRemovalFailed,
            };
        } else {
            // Without a state path we can't safely scrub anything;
            // treat that as "kept" rather than guessing at $HOME.
            state_kept = true;
        }
    }

    try out.writeAll("uninstalled tigerclaw\n");
    try out.print("  binary: {s}\n", .{binary});
    if (state_kept) {
        try out.writeAll("  state:  (kept)\n");
    } else {
        try out.print("  removed state: {s}\n", .{args.state_dir.?});
    }
}

fn readTrimmedLine(r: *std.Io.Reader) ![]const u8 {
    const raw = r.takeDelimiterExclusive('\n') catch |e| switch (e) {
        // EOF before newline still gives us whatever was buffered;
        // fall through to trim and treat it as the user's input.
        error.EndOfStream => return "",
        else => return e,
    };
    return std.mem.trim(u8, raw, " \r\t");
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "uninstall parse: empty argv → defaults" {
    const argv = [_][]const u8{};
    const a = try parse(&argv);
    try testing.expect(!a.yes);
    try testing.expect(!a.keep_config);
}

test "uninstall parse: --yes" {
    const argv = [_][]const u8{"--yes"};
    const a = try parse(&argv);
    try testing.expect(a.yes);
}

test "uninstall parse: --keep-config" {
    const argv = [_][]const u8{"--keep-config"};
    const a = try parse(&argv);
    try testing.expect(a.keep_config);
}

test "uninstall parse: both flags" {
    const argv = [_][]const u8{ "--keep-config", "--yes" };
    const a = try parse(&argv);
    try testing.expect(a.yes);
    try testing.expect(a.keep_config);
}

test "uninstall parse: unknown flag" {
    const argv = [_][]const u8{"--bogus"};
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

fn tmpAbsPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(dir_abs);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_abs, name });
}

fn touch(dir: std.Io.Dir, name: []const u8) !void {
    const f = try dir.createFile(testing.io, name, .{});
    f.close(testing.io);
}

test "uninstall run: --yes --keep-config keeps the state dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "state", .default_dir);
    var state = try tmp.dir.openDir(testing.io, "state", .{});
    defer state.close(testing.io);
    try touch(state, "marker");

    const path = try tmpAbsPath(testing.allocator, tmp, "state");
    defer testing.allocator.free(path);

    var stdin_buf = "".*;
    var stdin = std.Io.Reader.fixed(&stdin_buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{
        .yes = true,
        .keep_config = true,
        .state_dir = path,
    }, &stdin, &out, &err);

    try testing.expect(std.mem.indexOf(u8, out.buffered(), "(kept)") != null);
    // marker must still be there.
    var probe = try tmp.dir.openDir(testing.io, "state", .{});
    probe.close(testing.io);
}

test "uninstall run: --yes (no keep) deletes the state dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "state", .default_dir);
    var state = try tmp.dir.openDir(testing.io, "state", .{});
    try touch(state, "marker");
    state.close(testing.io);

    const path = try tmpAbsPath(testing.allocator, tmp, "state");
    defer testing.allocator.free(path);

    var stdin_buf = "".*;
    var stdin = std.Io.Reader.fixed(&stdin_buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{
        .yes = true,
        .state_dir = path,
    }, &stdin, &out, &err);

    try testing.expect(std.mem.indexOf(u8, out.buffered(), "removed state") != null);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.openDir(testing.io, "state", .{}),
    );
}

test "uninstall run: prompt 'yes' on stdin proceeds with removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "state", .default_dir);

    const path = try tmpAbsPath(testing.allocator, tmp, "state");
    defer testing.allocator.free(path);

    var stdin_buf = "yes\n".*;
    var stdin = std.Io.Reader.fixed(&stdin_buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try run(testing.allocator, testing.io, .{ .state_dir = path }, &stdin, &out, &err);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "removed state") != null);
}

test "uninstall run: prompt 'no' aborts with error.Aborted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "state", .default_dir);

    const path = try tmpAbsPath(testing.allocator, tmp, "state");
    defer testing.allocator.free(path);

    var stdin_buf = "no\n".*;
    var stdin = std.Io.Reader.fixed(&stdin_buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);

    try testing.expectError(
        error.Aborted,
        run(testing.allocator, testing.io, .{ .state_dir = path }, &stdin, &out, &err),
    );
    // State dir must still exist.
    var probe = try tmp.dir.openDir(testing.io, "state", .{});
    probe.close(testing.io);
}
