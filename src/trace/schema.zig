//! Trace file schema v2.
//!
//! A trace is a single JSON-lines file. The first line is the
//! `Envelope` — a versioned header carrying the hashes and mode that
//! callers need to verify a run was reproducible. Subsequent lines are
//! `Span` records.
//!
//! Tools that read traces MUST check `schema_version` before interpreting
//! any other field. A version mismatch is `error.UnsupportedSchema`, not
//! a best-effort parse.

const std = @import("std");

pub const schema_version: u16 = 2;

/// Runtime mode pinned at harness-start time. Mirrors the enum in
/// `settings/schema.zig::Mode`, but this module is the on-disk source of
/// truth (trace files outlive the binary).
pub const Mode = enum {
    run,
    bench,
    replay,
    eval,

    pub fn jsonStringify(self: Mode, w: *std.json.Stringify) !void {
        try w.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Mode {
        _ = allocator;
        _ = options;
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |s| {
                if (std.meta.stringToEnum(Mode, s)) |v| return v;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// 32-byte hex digest carrier. Empty string means "not set".
pub const Digest = struct {
    hex: []const u8 = "",

    pub fn isSet(self: Digest) bool {
        return self.hex.len > 0;
    }
};

/// First line of a trace file.
pub const Envelope = struct {
    schema_version: u16 = schema_version,
    trace_id: []const u8,
    run_id: []const u8,
    started_at_ns: i128,
    mode: Mode,
    dataset_hash: Digest = .{},
    golden_hash: Digest = .{},
    rubric_hash: Digest = .{},
    mutation_hash: Digest = .{},
};

pub const SchemaError = error{
    UnsupportedSchema,
};

/// Accept-or-reject check for reader code. Rejects any envelope whose
/// declared version does not match this build. Extend the `switch` here
/// when a new reader-compatible version lands.
pub fn checkVersion(envelope: Envelope) SchemaError!void {
    switch (envelope.schema_version) {
        schema_version => {},
        else => return error.UnsupportedSchema,
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "schema_version is pinned to the current on-disk format" {
    try testing.expectEqual(@as(u16, 2), schema_version);
}

test "Envelope: JSON roundtrip preserves every field" {
    const envelope = Envelope{
        .trace_id = "trace-abc",
        .run_id = "run-42",
        .started_at_ns = 1_700_000_000_000_000_000,
        .mode = .bench,
        .dataset_hash = .{ .hex = "aabb" },
        .golden_hash = .{ .hex = "ccdd" },
        .rubric_hash = .{ .hex = "eeff" },
        .mutation_hash = .{ .hex = "0011" },
    };

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, envelope, .{});
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(Envelope, testing.allocator, bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(schema_version, parsed.value.schema_version);
    try testing.expectEqualStrings(envelope.trace_id, parsed.value.trace_id);
    try testing.expectEqualStrings(envelope.run_id, parsed.value.run_id);
    try testing.expectEqual(envelope.started_at_ns, parsed.value.started_at_ns);
    try testing.expectEqual(Mode.bench, parsed.value.mode);
    try testing.expectEqualStrings("aabb", parsed.value.dataset_hash.hex);
    try testing.expectEqualStrings("ccdd", parsed.value.golden_hash.hex);
    try testing.expectEqualStrings("eeff", parsed.value.rubric_hash.hex);
    try testing.expectEqualStrings("0011", parsed.value.mutation_hash.hex);
}

test "Envelope: defaults leave hashes empty" {
    const envelope = Envelope{
        .trace_id = "t",
        .run_id = "r",
        .started_at_ns = 0,
        .mode = .run,
    };
    try testing.expect(!envelope.dataset_hash.isSet());
    try testing.expect(!envelope.golden_hash.isSet());
    try testing.expect(!envelope.rubric_hash.isSet());
    try testing.expect(!envelope.mutation_hash.isSet());
}

test "Mode: unknown variant rejected on parse" {
    const bad =
        \\{"schema_version":2,"trace_id":"t","run_id":"r","started_at_ns":0,"mode":"train"}
    ;
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Envelope, testing.allocator, bad, .{}),
    );
}

test "checkVersion: current version is accepted" {
    const envelope = Envelope{
        .trace_id = "t",
        .run_id = "r",
        .started_at_ns = 0,
        .mode = .run,
    };
    try checkVersion(envelope);
}

test "checkVersion: foreign version is rejected" {
    var envelope = Envelope{
        .trace_id = "t",
        .run_id = "r",
        .started_at_ns = 0,
        .mode = .run,
    };
    envelope.schema_version = 99;
    try testing.expectError(error.UnsupportedSchema, checkVersion(envelope));
}

test "Digest.isSet distinguishes empty from populated" {
    const empty = Digest{};
    const full = Digest{ .hex = "dead" };
    try testing.expect(!empty.isSet());
    try testing.expect(full.isSet());
}
