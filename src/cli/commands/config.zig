//! `tigerclaw config <verb>` sub-verb parser.
//!
//! Verbs:
//!
//!   show      — print the resolved (env-overlayed) config as JSONC
//!   get KEY   — print a single dotted value
//!   set KEY VALUE — update a dotted value (routed through
//!                   settings.apply_change)
//!   unset KEY — remove a dotted value
//!   validate  — run the schema validator against the on-disk config
//!   edit      — open the config file in `$EDITOR`
//!   file      — print the resolved config path
//!
//! Execution lives next to the settings subsystem. This module is
//! argv-only.

const std = @import("std");

pub const Verb = union(enum) {
    show,
    get: []const u8,
    set: SetArgs,
    unset: []const u8,
    validate,
    edit,
    file,
};

pub const SetArgs = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    MissingSubVerb,
    UnknownSubVerb,
    MissingKey,
    MissingValue,
    UnknownFlag,
};

pub fn parse(argv: []const []const u8) ParseError!Verb {
    if (argv.len == 0) return error.MissingSubVerb;

    const sub = argv[0];
    const rest = argv[1..];

    if (std.mem.eql(u8, sub, "show")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .show;
    }
    if (std.mem.eql(u8, sub, "validate")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .validate;
    }
    if (std.mem.eql(u8, sub, "edit")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .edit;
    }
    if (std.mem.eql(u8, sub, "file")) {
        if (rest.len != 0) return error.UnknownFlag;
        return .file;
    }
    if (std.mem.eql(u8, sub, "get")) {
        if (rest.len == 0) return error.MissingKey;
        if (rest.len > 1) return error.UnknownFlag;
        return .{ .get = rest[0] };
    }
    if (std.mem.eql(u8, sub, "unset")) {
        if (rest.len == 0) return error.MissingKey;
        if (rest.len > 1) return error.UnknownFlag;
        return .{ .unset = rest[0] };
    }
    if (std.mem.eql(u8, sub, "set")) {
        if (rest.len == 0) return error.MissingKey;
        if (rest.len == 1) return error.MissingValue;
        if (rest.len > 2) return error.UnknownFlag;
        return .{ .set = .{ .key = rest[0], .value = rest[1] } };
    }

    return error.UnknownSubVerb;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse: config show takes no args" {
    const argv = [_][]const u8{"show"};
    try testing.expectEqual(Verb.show, try parse(&argv));
}

test "parse: config show with args → UnknownFlag" {
    const argv = [_][]const u8{ "show", "--json" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: config get <key>" {
    const argv = [_][]const u8{ "get", "providers.default" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("providers.default", v.get);
}

test "parse: config get without key → MissingKey" {
    const argv = [_][]const u8{"get"};
    try testing.expectError(error.MissingKey, parse(&argv));
}

test "parse: config set <key> <value>" {
    const argv = [_][]const u8{ "set", "log_level", "debug" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("log_level", v.set.key);
    try testing.expectEqualStrings("debug", v.set.value);
}

test "parse: config set with key but no value → MissingValue" {
    const argv = [_][]const u8{ "set", "log_level" };
    try testing.expectError(error.MissingValue, parse(&argv));
}

test "parse: config set with trailing garbage → UnknownFlag" {
    const argv = [_][]const u8{ "set", "a", "b", "c" };
    try testing.expectError(error.UnknownFlag, parse(&argv));
}

test "parse: config unset <key>" {
    const argv = [_][]const u8{ "unset", "log_level" };
    const v = try parse(&argv);
    try testing.expectEqualStrings("log_level", v.unset);
}

test "parse: config validate takes no args" {
    const argv = [_][]const u8{"validate"};
    try testing.expectEqual(Verb.validate, try parse(&argv));
}

test "parse: config edit takes no args" {
    const argv = [_][]const u8{"edit"};
    try testing.expectEqual(Verb.edit, try parse(&argv));
}

test "parse: config file takes no args" {
    const argv = [_][]const u8{"file"};
    try testing.expectEqual(Verb.file, try parse(&argv));
}

test "parse: config empty argv → MissingSubVerb" {
    const argv = [_][]const u8{};
    try testing.expectError(error.MissingSubVerb, parse(&argv));
}

test "parse: config unknown sub-verb → UnknownSubVerb" {
    const argv = [_][]const u8{"export"};
    try testing.expectError(error.UnknownSubVerb, parse(&argv));
}
