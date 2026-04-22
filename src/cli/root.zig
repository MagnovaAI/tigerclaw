//! CLI front door.
//!
//! Routes top-level argv into either a legacy `Command` union value
//! (for verbs whose behaviour is inlined in `main.zig`) or a typed
//! handler call site (for verbs implemented in `src/cli/commands/*`).

const std = @import("std");
const version = @import("../version.zig");

pub const descriptor = @import("descriptor.zig");
pub const presentation = @import("presentation.zig");
pub const commands = struct {
    pub const doctor = @import("commands/doctor.zig");
    pub const completion = @import("commands/completion.zig");
    pub const agent_selector = @import("commands/agent_selector.zig");
    pub const agents = @import("commands/agents.zig");
    pub const gateway = @import("commands/gateway.zig");
    pub const sessions = @import("commands/sessions.zig");
    pub const config = @import("commands/config.zig");
    pub const http_client = @import("commands/http_client.zig");
    pub const agent = @import("commands/agent.zig");
    pub const channels = @import("commands/channels.zig");
    pub const cassette = @import("commands/cassette.zig");
    pub const providers = @import("commands/providers.zig");
    pub const models = @import("commands/models.zig");
    pub const diag = @import("commands/diag.zig");
};

pub const version_string = version.string;

pub const AgentArgs = struct {
    /// Defaults to "http://127.0.0.1:8765" — the canonical local
    /// gateway address. Override via --base-url.
    base_url: []const u8 = "http://127.0.0.1:8765",
    /// Session id targeted by the turn. Defaults to the mock session
    /// the gateway accepts in v0.1.0.
    session_id: []const u8 = "mock-session",
    /// Optional bearer token for gateway auth.
    bearer: ?[]const u8 = null,
};

pub const Command = union(enum) {
    version,
    help,
    doctor,
    completion: commands.completion.Shell,
    agent: AgentArgs,
    channels: commands.channels.Subcommand,
    cassette: commands.cassette.Subcommand,
    providers: commands.providers.Subcommand,
    models: commands.models.Subcommand,
    diag: commands.diag.Subcommand,
    gateway_logs: commands.gateway.LogsOptions,
    unknown: []const u8,
};

pub const ParseError = error{
    MissingCommand,
    CompletionMissingShell,
    CompletionUnknownShell,
    UnknownFlag,
    MissingFlagValue,
    ChannelsMissingSubcommand,
    ChannelsUnknownSubcommand,
    ChannelsTelegramTestMissingFields,
    CassetteMissingSubcommand,
    CassetteUnknownSubcommand,
    CassetteMissingPath,
    ProvidersMissingSubcommand,
    ProvidersUnknownSubcommand,
    ModelsMissingSubcommand,
    ModelsUnknownSubcommand,
    ModelsMissingModel,
    DiagMissingSubcommand,
    DiagUnknownSubcommand,
    DiagMissingEventId,
    DiagInvalidLineCount,
    GatewayLogsInvalidTailCount,
    GatewayLogsConflictingFlags,
};

/// Top-level command table. Summaries feed the help screen and shell
/// completion generators.
pub const command_table = [_]descriptor.CommandDescriptor{
    .{ .name = "agent", .summary = "Stream a turn from the local gateway and render tokens" },
    .{ .name = "cassette", .summary = "Inspect and replay VCR cassettes" },
    .{ .name = "channels", .summary = "List, inspect, and probe configured channels" },
    .{ .name = "providers", .summary = "List LLM providers and probe reachability" },
    .{ .name = "models", .summary = "List known models, show the default, override per session" },
    .{ .name = "diag", .summary = "Inspect recent diagnostic events" },
    .{ .name = "gateway", .summary = "Gateway daemon controls (logs in v0.1.0)" },
    .{ .name = "version", .summary = "Print the version and exit" },
    .{ .name = "help", .summary = "Print this message" },
    .{ .name = "doctor", .summary = "Print a short environment report" },
    .{ .name = "completion", .summary = "Print a shell completion script (bash|zsh|fish)" },
};

/// Parse argv[1..]. `argv` must not include the program name.
pub fn parse(argv: []const []const u8) ParseError!Command {
    if (argv.len == 0) return error.MissingCommand;

    const first = argv[0];

    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        return .version;
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .help;
    }

    const match = descriptor.resolve(&command_table, argv) catch |err| switch (err) {
        error.MissingCommand => return error.MissingCommand,
        error.UnknownCommand => return .{ .unknown = first },
    };

    if (std.mem.eql(u8, match.descriptor.name, "version")) return .version;
    if (std.mem.eql(u8, match.descriptor.name, "help")) return .help;
    if (std.mem.eql(u8, match.descriptor.name, "doctor")) return .doctor;
    if (std.mem.eql(u8, match.descriptor.name, "completion")) {
        if (match.argv.len < 2) return error.CompletionMissingShell;
        const shell = commands.completion.parseShell(match.argv[1]) catch return error.CompletionUnknownShell;
        return .{ .completion = shell };
    }
    if (std.mem.eql(u8, match.descriptor.name, "agent")) {
        return parseAgent(match.argv[1..]);
    }
    if (std.mem.eql(u8, match.descriptor.name, "channels")) {
        const sub = commands.channels.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubcommand => return error.ChannelsMissingSubcommand,
            error.UnknownSubcommand => return error.ChannelsUnknownSubcommand,
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
            error.TelegramTestMissingFields => return error.ChannelsTelegramTestMissingFields,
        };
        return .{ .channels = sub };
    }
    if (std.mem.eql(u8, match.descriptor.name, "providers")) {
        const sub = commands.providers.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubcommand => return error.ProvidersMissingSubcommand,
            error.UnknownSubcommand => return error.ProvidersUnknownSubcommand,
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
        };
        return .{ .providers = sub };
    }
    if (std.mem.eql(u8, match.descriptor.name, "cassette")) {
        const sub = commands.cassette.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubcommand => return error.CassetteMissingSubcommand,
            error.UnknownSubcommand => return error.CassetteUnknownSubcommand,
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
            error.MissingPath => return error.CassetteMissingPath,
        };
        return .{ .cassette = sub };
    }
    if (std.mem.eql(u8, match.descriptor.name, "models")) {
        const sub = commands.models.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubcommand => return error.ModelsMissingSubcommand,
            error.UnknownSubcommand => return error.ModelsUnknownSubcommand,
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
            error.MissingPositional => return error.ModelsMissingModel,
        };
        return .{ .models = sub };
    }
    if (std.mem.eql(u8, match.descriptor.name, "diag")) {
        const sub = commands.diag.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubcommand => return error.DiagMissingSubcommand,
            error.UnknownSubcommand => return error.DiagUnknownSubcommand,
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
            error.MissingEventId => return error.DiagMissingEventId,
            error.InvalidLineCount => return error.DiagInvalidLineCount,
        };
        return .{ .diag = sub };
    }
    if (std.mem.eql(u8, match.descriptor.name, "gateway")) {
        // v0.1.0 only wires up the `logs` sub-verb from the CLI. The
        // daemon control verbs (start/stop/status/restart/serve) are
        // parsed by `commands.gateway.parse` but not yet dispatched
        // from main — flag them as unknown so users aren't misled.
        const verb = commands.gateway.parse(match.argv[1..]) catch |err| switch (err) {
            error.MissingSubVerb, error.UnknownSubVerb => return .{ .unknown = "gateway" },
            error.UnknownFlag => return error.UnknownFlag,
            error.MissingFlagValue => return error.MissingFlagValue,
            error.InvalidTailCount => return error.GatewayLogsInvalidTailCount,
            error.ConflictingFlags => return error.GatewayLogsConflictingFlags,
        };
        switch (verb) {
            .logs => |opts| return .{ .gateway_logs = opts },
            else => return .{ .unknown = "gateway" },
        }
    }

    return .{ .unknown = first };
}

fn parseAgent(rest: []const []const u8) ParseError!Command {
    var args: AgentArgs = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--base-url")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.base_url = rest[i];
        } else if (std.mem.eql(u8, flag, "--session")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.session_id = rest[i];
        } else if (std.mem.eql(u8, flag, "--bearer")) {
            if (i + 1 >= rest.len) return error.MissingFlagValue;
            i += 1;
            args.bearer = rest[i];
        } else {
            return error.UnknownFlag;
        }
    }
    return .{ .agent = args };
}

pub fn printVersion(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("tigerclaw {s}\n", .{version_string});
}

pub fn printHelp(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try presentation.writeBanner(w);
    try w.writeAll("\nUsage:\n  tigerclaw <command> [options]\n\n");

    try w.writeAll("Options:\n");
    const OptionRow = struct { name: []const u8, summary: []const u8 };
    const options = [_]OptionRow{
        .{ .name = "-h, --help", .summary = "Print this message" },
        .{ .name = "-V, --version", .summary = "Print the version and exit" },
    };
    try presentation.writeTable(w, OptionRow, &options, 14);

    try w.writeAll("\nCommands:\n");
    try presentation.writeTable(
        w,
        descriptor.CommandDescriptor,
        &command_table,
        14,
    );

    try w.writeAll("\nMore commands land as subsystems are added. See docs/ARCHITECTURE.md.\n");
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: --version flag" {
    const argv = [_][]const u8{"--version"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: -V short flag" {
    const argv = [_][]const u8{"-V"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: --help flag" {
    const argv = [_][]const u8{"--help"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: -h short flag" {
    const argv = [_][]const u8{"-h"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: version verb via descriptor table" {
    const argv = [_][]const u8{"version"};
    try testing.expectEqual(Command.version, try parse(&argv));
}

test "parse: help verb via descriptor table" {
    const argv = [_][]const u8{"help"};
    try testing.expectEqual(Command.help, try parse(&argv));
}

test "parse: doctor verb via descriptor table" {
    const argv = [_][]const u8{"doctor"};
    try testing.expectEqual(Command.doctor, try parse(&argv));
}

test "parse: completion bash → Command.completion{.bash}" {
    const argv = [_][]const u8{ "completion", "bash" };
    const cmd = try parse(&argv);
    try testing.expectEqual(commands.completion.Shell.bash, cmd.completion);
}

test "parse: completion without shell returns CompletionMissingShell" {
    const argv = [_][]const u8{"completion"};
    try testing.expectError(error.CompletionMissingShell, parse(&argv));
}

test "parse: completion with unknown shell returns CompletionUnknownShell" {
    const argv = [_][]const u8{ "completion", "tcsh" };
    try testing.expectError(error.CompletionUnknownShell, parse(&argv));
}

test "parse: unknown token returns .unknown" {
    const argv = [_][]const u8{"--nope"};
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("--nope", cmd.unknown);
}

test "parse: empty argv returns MissingCommand" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingCommand, parse(&argv));
}

test "printVersion writes the expected string" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printVersion(&w);
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "tigerclaw {s}\n", .{version.string});
    try testing.expectEqualStrings(expected, w.buffered());
}

test "printHelp: mentions banner, both flags, and the verbs in the table" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printHelp(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "tigerclaw — agent runtime") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--version") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try testing.expect(std.mem.indexOf(u8, out, "doctor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "completion") != null);
}

test "parse: agent verb with no flags yields defaults" {
    const argv = [_][]const u8{"agent"};
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("http://127.0.0.1:8765", cmd.agent.base_url);
    try testing.expectEqualStrings("mock-session", cmd.agent.session_id);
    try testing.expect(cmd.agent.bearer == null);
}

test "parse: agent --session overrides session_id" {
    const argv = [_][]const u8{ "agent", "--session", "abc" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("abc", cmd.agent.session_id);
}

test "parse: agent with all three flags set" {
    const argv = [_][]const u8{ "agent", "--base-url", "http://x:1", "--session", "s", "--bearer", "t" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("http://x:1", cmd.agent.base_url);
    try testing.expectEqualStrings("s", cmd.agent.session_id);
    try testing.expectEqualStrings("t", cmd.agent.bearer.?);
}

test "parse: agent with unknown flag returns UnknownFlag" {
    const argv = [_][]const u8{ "agent", "--nope" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: channels list → Command.channels{.list}" {
    const argv = [_][]const u8{ "channels", "list" };
    const cmd = try parse(&argv);
    try testing.expectEqual(commands.channels.Subcommand.list, cmd.channels);
}

test "parse: channels telegram enable → Command.channels{.telegram_enable}" {
    const argv = [_][]const u8{ "channels", "telegram", "enable" };
    const cmd = try parse(&argv);
    try testing.expectEqual(commands.channels.Subcommand.telegram_enable, cmd.channels);
}

test "parse: channels with no subcommand → ChannelsMissingSubcommand" {
    const argv = [_][]const u8{"channels"};
    try testing.expectError(error.ChannelsMissingSubcommand, parse(&argv));
}

test "parse: cassette list → Command.cassette{.list}" {
    const argv = [_][]const u8{ "cassette", "list" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("tests/cassettes", cmd.cassette.list.dir);
}

test "parse: cassette show <path> → Command.cassette{.show}" {
    const argv = [_][]const u8{ "cassette", "show", "/tmp/x.jsonl" };
    const cmd = try parse(&argv);
    try testing.expectEqualStrings("/tmp/x.jsonl", cmd.cassette.show.path);
}

test "parse: cassette with no subcommand → CassetteMissingSubcommand" {
    const argv = [_][]const u8{"cassette"};
    try testing.expectError(error.CassetteMissingSubcommand, parse(&argv));
}

test {
    testing.refAllDecls(@This());
}
