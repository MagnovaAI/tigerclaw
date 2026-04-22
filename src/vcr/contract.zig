//! Provider-contract VCR helpers.
//!
//! WHY: provider integration tests want to drive a real provider against
//! a recorded HTTP cassette so that CI runs hermetically (no network,
//! no API keys) while still letting a developer with valid keys re-record
//! the cassette on demand. This module owns the small bit of policy that
//! decides between three states: replay an existing cassette, skip the
//! test (cassette missing OR key missing), or take the record path
//! (which is currently a stub — the live HTTP plumbing lands later).
//!
//! Keeping the decision in one place means each provider's test file
//! only has to call `decide` and switch on the result. Adding a fourth
//! mode or a new gating rule later is a one-file change.

const std = @import("std");

/// Three modes the contract test can run in.
///
///   * `.replay` — load the cassette from disk and drive the provider
///     from its recorded bytes. The default. Used by CI and any dev
///     machine without API keys.
///   * `.record` — perform a real HTTP call and append the
///     request/response pair to the cassette. Requires the provider's
///     API key env var to be set. Live wiring is not implemented yet,
///     so this currently lands on the `record_pending` branch.
///   * `.live`   — like `record` but does not write to disk; intended
///     for one-off smoke checks against a real backend. Same wiring
///     dependency, so it also lands on `record_pending` for now.
pub const Mode = enum { replay, record, live };

/// Map an env-var value (typically read from `TIGERCLAW_VCR_MODE`) to a
/// `Mode`. Unknown / null values fall back to `.replay` because the
/// safe default is to never touch the network.
pub fn resolveMode(env_value: ?[]const u8) Mode {
    const v = env_value orelse return .replay;
    if (std.mem.eql(u8, v, "replay")) return .replay;
    if (std.mem.eql(u8, v, "record")) return .record;
    if (std.mem.eql(u8, v, "live")) return .live;
    return .replay;
}

/// What the caller should do for this test invocation.
pub const ContractDecision = union(enum) {
    /// Cassette exists and we are in replay mode — load it and drive
    /// the provider from the recorded bytes.
    replay: struct { cassette_path: []const u8 },
    /// Test cannot run (cassette missing in replay mode, or API key
    /// missing in record/live mode). Caller should `return error.SkipZigTest`.
    skip: void,
    /// Caller is in record/live mode AND has an API key — but the
    /// live HTTP wiring is not implemented yet, so the actual record
    /// step is deferred. Tests treat this as a skip with a TODO note.
    record_pending: void,
};

/// Decide which branch the contract test should take.
///
/// `dir` is the directory the `cassette_path` is resolved against
/// (typically the test process cwd via `std.testing` helpers, or a
/// caller-supplied `Io.Dir`). `cassette_path` is relative to `dir`.
pub fn decide(
    io: std.Io,
    dir: std.Io.Dir,
    cassette_path: []const u8,
    mode: Mode,
    api_key: ?[]const u8,
) !ContractDecision {
    switch (mode) {
        .replay => {
            const exists = try cassetteExists(io, dir, cassette_path);
            if (!exists) return .skip;
            return .{ .replay = .{ .cassette_path = cassette_path } };
        },
        .record, .live => {
            if (api_key == null or api_key.?.len == 0) return .skip;
            return .record_pending;
        },
    }
}

fn cassetteExists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "resolveMode: null and unknown fall back to replay" {
    try testing.expectEqual(Mode.replay, resolveMode(null));
    try testing.expectEqual(Mode.replay, resolveMode(""));
    try testing.expectEqual(Mode.replay, resolveMode("garbage"));
}

test "resolveMode: known values map directly" {
    try testing.expectEqual(Mode.replay, resolveMode("replay"));
    try testing.expectEqual(Mode.record, resolveMode("record"));
    try testing.expectEqual(Mode.live, resolveMode("live"));
}

test "decide: replay + cassette missing -> skip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const d = try decide(testing.io, tmp.dir, "missing.jsonl", .replay, null);
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .skip), std.meta.activeTag(d));
}

test "decide: replay + cassette present -> replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Touch a file to make it discoverable.
    var f = try tmp.dir.createFile(testing.io, "present.jsonl", .{});
    f.close(testing.io);

    const d = try decide(testing.io, tmp.dir, "present.jsonl", .replay, null);
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .replay), std.meta.activeTag(d));
    try testing.expectEqualStrings("present.jsonl", d.replay.cassette_path);
}

test "decide: record without key -> skip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const d = try decide(testing.io, tmp.dir, "any.jsonl", .record, null);
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .skip), std.meta.activeTag(d));

    const d2 = try decide(testing.io, tmp.dir, "any.jsonl", .record, "");
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .skip), std.meta.activeTag(d2));
}

test "decide: record with key -> record_pending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const d = try decide(testing.io, tmp.dir, "any.jsonl", .record, "sk-live");
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .record_pending), std.meta.activeTag(d));
}

test "decide: live without key -> skip; live with key -> record_pending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const a = try decide(testing.io, tmp.dir, "x.jsonl", .live, null);
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .skip), std.meta.activeTag(a));

    const b = try decide(testing.io, tmp.dir, "x.jsonl", .live, "sk-live");
    try testing.expectEqual(@as(std.meta.Tag(ContractDecision), .record_pending), std.meta.activeTag(b));
}
