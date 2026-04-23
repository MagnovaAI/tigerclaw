//! Live Telegram smoke test — drives the real API using whatever
//! token is in TIGERCLAW_TG_TOKEN. Asserts the full handshake path:
//!
//!   startup.bind -> Bot.deleteWebhookKeepPending -> Bot.getMe
//!                -> TelegramChannel wrapping -> Manager.add
//!
//! Runs iff the env var is set; otherwise it skips with a log line.
//! NOT wired into `zig build test` — callers invoke it directly:
//!
//!   zig test tests/live_telegram_smoke.zig \
//!     --mod channels_spec:::src/channels/spec.zig \
//!     ... (see the one-shot command below)
//!
//! Or more practically, add it to build.zig as an integration test
//! only when we want live CI. For manual use today, run via the
//! companion bash wrapper at the bottom of the PR description.

const std = @import("std");
const tigerclaw = @import("tigerclaw");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    // Fake registry with one agent: Tiger, telegram, token_env=TIGERCLAW_TG_TOKEN.
    const entries = [_]tigerclaw.harness.agent_registry.Agent{
        .{
            .name = "tiger",
            .persona = "",
            .provider = "mock",
            .model = "mock-sonnet",
            .monthly_budget_cents = 0,
            .enabled = true,
            .channel = .{
                .kind = .telegram,
                .account = "tobi374758_bot",
                .token_env = "TIGERCLAW_TG_TOKEN",
            },
        },
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry: tigerclaw.harness.agent_registry.Registry = .{
        .arena = arena,
        .entries = @constCast(&entries),
        .default_name = "tiger",
    };

    var dispatch = try tigerclaw.channels.dispatch.Dispatch.init(allocator, 8);
    defer dispatch.deinit();

    var manager = tigerclaw.channels.manager.Manager.init(allocator, io, &dispatch);
    defer manager.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_writer.interface.flush() catch {};

    var channels = tigerclaw.channels.startup.bind(
        allocator,
        io,
        &registry,
        &manager,
        &stdout_writer.interface,
    ) catch |err| {
        try stdout_writer.interface.print("bind failed: {s}\n", .{@errorName(err)});
        try stdout_writer.interface.flush();
        return err;
    };
    defer channels.deinit();

    try stdout_writer.interface.print(
        "OK: 1 telegram channel bound; manager.get(\"tiger\", .telegram) = {any}\n",
        .{manager.get("tiger", .telegram) != null},
    );
    return 0;
}
