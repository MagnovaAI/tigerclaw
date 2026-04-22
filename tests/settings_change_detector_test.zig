//! Integration: atomic write + change_detector + secrets redaction on a
//! real temp directory.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const settings = tigerclaw.settings;

const testing = std.testing;

test "end-to-end: write, detect change, reload, redact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial =
        \\{"log_level":"info","openai_api_key":"sk-initial"}
    ;
    try settings.internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.jsonc", initial);

    var detector = settings.change_detector.Detector.init();
    try testing.expectEqual(
        settings.change_detector.Event.appeared,
        try detector.poll(tmp.dir, testing.io, "cfg.jsonc"),
    );
    try testing.expectEqual(
        settings.change_detector.Event.unchanged,
        try detector.poll(tmp.dir, testing.io, "cfg.jsonc"),
    );

    const updated =
        \\{"log_level":"debug","openai_api_key":"sk-rotated"}
    ;
    try settings.internal_writes.writeAtomic(tmp.dir, testing.io, "cfg.jsonc", updated);
    try testing.expectEqual(
        settings.change_detector.Event.changed,
        try detector.poll(tmp.dir, testing.io, "cfg.jsonc"),
    );

    // Read the new contents and redact before any logging would happen.
    var read_buf: [256]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "cfg.jsonc", &read_buf);
    const redacted = try settings.secrets.redact(testing.allocator, bytes);
    defer testing.allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "sk-rotated") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "\"***\"") != null);

    try tmp.dir.deleteFile(testing.io, "cfg.jsonc");
    try testing.expectEqual(
        settings.change_detector.Event.removed,
        try detector.poll(tmp.dir, testing.io, "cfg.jsonc"),
    );
}

test "mdm overrides beat everything else, including apply_change" {
    var cache = settings.Cache.init();
    try settings.apply_change.apply(testing.allocator, &cache, .{ .mode = .bench });
    try testing.expectEqual(settings.Mode.bench, cache.get().mode);

    var snapshot = cache.get();
    settings.mdm.applyOverrides(&snapshot, .{ .mode = .replay });
    cache.install(snapshot);

    try testing.expectEqual(settings.Mode.replay, cache.get().mode);
}
