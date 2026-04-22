const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/root.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stdout_w.interface.flush() catch {};
    defer stderr_w.interface.flush() catch {};

    if (argv.len < 2) {
        try cli.printHelp(&stderr_w.interface);
        return 64; // EX_USAGE
    }

    // Convert [:0]const u8 slices to []const u8 for the parser.
    const tail = try arena.alloc([]const u8, argv.len - 1);
    for (argv[1..], 0..) |a, i| tail[i] = a;

    const cmd = cli.parse(tail) catch |err| switch (err) {
        error.MissingCommand => {
            try cli.printHelp(&stderr_w.interface);
            return 64;
        },
        error.CompletionMissingShell => {
            try stderr_w.interface.writeAll("tigerclaw: completion requires a shell (bash|zsh|fish)\n");
            return 64;
        },
        error.CompletionUnknownShell => {
            try stderr_w.interface.writeAll("tigerclaw: unknown completion shell; expected bash|zsh|fish\n");
            return 64;
        },
        error.UnknownFlag => {
            try stderr_w.interface.writeAll("tigerclaw: unknown flag\n");
            return 64;
        },
        error.MissingFlagValue => {
            try stderr_w.interface.writeAll("tigerclaw: flag requires a value\n");
            return 64;
        },
        error.ChannelsMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: channels requires a subcommand (list|status|telegram)\n");
            return 64;
        },
        error.ChannelsUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown channels subcommand\n");
            return 64;
        },
        error.ChannelsTelegramTestMissingFields => {
            try stderr_w.interface.writeAll("tigerclaw: channels telegram test requires --to and --text\n");
            return 64;
        },
        error.CassetteMissingSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: cassette requires a subcommand (list|show|replay)\n");
            return 64;
        },
        error.CassetteUnknownSubcommand => {
            try stderr_w.interface.writeAll("tigerclaw: unknown cassette subcommand\n");
            return 64;
        },
        error.CassetteMissingPath => {
            try stderr_w.interface.writeAll("tigerclaw: cassette show/replay requires a path\n");
            return 64;
        },
    };

    switch (cmd) {
        .version => try cli.printVersion(&stdout_w.interface),
        .help => try cli.printHelp(&stdout_w.interface),
        .doctor => try runDoctor(arena, init.environ_map, &stdout_w.interface),
        .completion => |shell| try cli.commands.completion.write(
            &stdout_w.interface,
            shell,
            &cli.command_table,
        ),
        .agent => |args| {
            cli.commands.agent.installInterruptHandler();
            const opts: cli.commands.agent.Options = .{
                .base_url = args.base_url,
                .session_id = args.session_id,
                .bearer = args.bearer,
                .out = &stdout_w.interface,
            };
            cli.commands.agent.run(arena, io, opts) catch |err| switch (err) {
                error.Interrupted => return 130,
                error.GatewayDown => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway unreachable\n");
                    return 69; // EX_UNAVAILABLE
                },
                error.Unauthorized => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected credentials\n");
                    return 77; // EX_NOPERM
                },
                error.BadRequest => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected the request\n");
                    return 65; // EX_DATAERR
                },
                error.InternalError => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway internal error\n");
                    return 70; // EX_SOFTWARE
                },
                error.InvalidResponse => {
                    try stderr_w.interface.writeAll("tigerclaw: invalid gateway response\n");
                    return 70;
                },
                error.UrlTooLong => {
                    try stderr_w.interface.writeAll("tigerclaw: base_url + session id too long\n");
                    return 64;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        .channels => |sub| {
            cli.commands.channels.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.GatewayDown => return 1,
                error.Unauthorized => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected credentials\n");
                    return 77;
                },
                error.BadRequest => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway rejected the request\n");
                    return 65;
                },
                error.InternalError => {
                    try stderr_w.interface.writeAll("tigerclaw: gateway internal error\n");
                    return 70;
                },
                error.InvalidResponse => {
                    try stderr_w.interface.writeAll("tigerclaw: invalid gateway response\n");
                    return 70;
                },
                error.UrlTooLong, error.BodyTooLarge => {
                    try stderr_w.interface.writeAll("tigerclaw: request payload too large\n");
                    return 64;
                },
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .cassette => |sub| {
            cli.commands.cassette.run(
                arena,
                io,
                sub,
                &stdout_w.interface,
                &stderr_w.interface,
            ) catch |err| switch (err) {
                error.DirNotFound, error.FileNotFound, error.InvalidCassette, error.ReadFailed => return 1,
                error.OutOfMemory, error.WriteFailed => return err,
            };
        },
        .unknown => |flag| {
            try stderr_w.interface.print("tigerclaw: unknown option '{s}'\n\n", .{flag});
            try cli.printHelp(&stderr_w.interface);
            return 64;
        },
    }
    return 0;
}

fn runDoctor(
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    w: *std.Io.Writer,
) !void {
    try cli.commands.doctor.writeReport(arena, w, .{
        .zig_version = builtin.zig_version_string,
        .os_tag = @tagName(builtin.target.os.tag),
        .arch_tag = @tagName(builtin.target.cpu.arch),
        .env_config = environ_map.get("TIGERCLAW_CONFIG"),
        .env_xdg = environ_map.get("XDG_CONFIG_HOME"),
        .env_home = environ_map.get("HOME"),
    });
}

test {
    // Pull in tests from the library surface so `zig build test`
    // (rooted at main.zig) sees all of them.
    std.testing.refAllDecls(@import("root.zig"));
}
