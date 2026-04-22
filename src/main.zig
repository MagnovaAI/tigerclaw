const std = @import("std");
const cli = @import("cli.zig");

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
    };

    switch (cmd) {
        .version => try cli.printVersion(&stdout_w.interface),
        .help => try cli.printHelp(&stdout_w.interface),
        .unknown => |flag| {
            try stderr_w.interface.print("tigerclaw: unknown option '{s}'\n\n", .{flag});
            try cli.printHelp(&stderr_w.interface);
            return 64;
        },
    }
    return 0;
}

test {
    // Pull in tests from the library surface so `zig build test`
    // (rooted at main.zig) sees all of them.
    std.testing.refAllDecls(@import("root.zig"));
}
