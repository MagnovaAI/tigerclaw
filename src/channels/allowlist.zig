//! Per-sender allowlist + rate limit.
//!
//! v0.1.0 abuse control: the dispatch worker calls `Allowlist.admit`
//! on every inbound message; messages whose `sender_id` is not on the
//! list are dropped. Wildcard `"*"` admits everyone but flags the
//! allowlist as wildcard so operators can surface a one-shot warning.
//! A token bucket limits each sender to `rate_per_second` messages
//! with a burst of `ceil(rate * 4)`.
//!
//! The allowlist is stateless from the caller's perspective: it is
//! rebuilt from config on every reload. Internal bucket state uses a
//! `StringHashMap` keyed by owned copies of the sender ids.
//!
//! ## Concurrency
//!
//! `admit` is NOT thread-safe. The channel manager keeps a single
//! dispatch worker thread so only one `admit` call is in flight at a
//! time; making the allowlist lock-free is the right trade-off there.
//! If the dispatch fan-out ever grows a second worker, this file will
//! need a mutex around the hashmap + per-bucket refill.

const std = @import("std");

pub const Decision = enum {
    /// Sender is on the list AND has bucket tokens — admit.
    allow,
    /// Sender is not on the allowlist — drop, no apology.
    rejected_unauthorized,
    /// Sender is on the list but has used its bucket — drop with
    /// a log breadcrumb. The dispatcher does not retry; the upstream
    /// channel will re-deliver if the user resends.
    rejected_rate_limited,
};

pub const Config = struct {
    /// Caller-owned slice of stable sender ids. Wildcard `"*"` means
    /// "admit everyone"; mixing `"*"` with explicit ids is treated as
    /// a misconfiguration and returns `ConfigError.WildcardWithEntries`
    /// at construction time.
    senders: []const []const u8,
    /// Tokens per second per sender. Default 1.0 = roughly one message
    /// per second.
    rate_per_second: f64 = 1.0,
};

pub const ConfigError = error{
    WildcardWithEntries,
};

const Bucket = struct {
    tokens: f64,
    last_refill_ms: i64,
};

pub const Allowlist = struct {
    allocator: std.mem.Allocator,
    wildcard: bool,
    rate_per_ms: f64,
    burst: f64,
    /// Keyed by sender id. For explicit entries the key is an owned
    /// dupe of the config string; for wildcard mode a single entry
    /// keyed by the empty string acts as the shared bucket.
    buckets: std.StringHashMap(Bucket),
    /// Marker key used in wildcard mode. Borrowed static — never
    /// freed — so wildcard mode never touches the allocator after
    /// init beyond the map itself.
    const wildcard_key: []const u8 = "";

    pub fn init(allocator: std.mem.Allocator, cfg: Config) (ConfigError || std.mem.Allocator.Error)!Allowlist {
        var has_wildcard = false;
        var explicit_count: usize = 0;
        for (cfg.senders) |s| {
            if (std.mem.eql(u8, s, "*")) {
                has_wildcard = true;
            } else {
                explicit_count += 1;
            }
        }
        if (has_wildcard and explicit_count > 0) return ConfigError.WildcardWithEntries;

        const rate = cfg.rate_per_second;
        const burst_u: u32 = @max(@as(u32, 1), @as(u32, @intFromFloat(@ceil(rate * 4.0))));
        const burst: f64 = @floatFromInt(burst_u);

        var buckets = std.StringHashMap(Bucket).init(allocator);
        errdefer buckets.deinit();

        if (has_wildcard) {
            try buckets.put(wildcard_key, .{ .tokens = burst, .last_refill_ms = 0 });
        } else {
            try buckets.ensureTotalCapacity(@intCast(cfg.senders.len));
            for (cfg.senders) |s| {
                // `getOrPut` semantics: if the caller listed a sender
                // twice we keep the first-seen bucket and skip the
                // duplicate dupe. Silently tolerant because config is
                // often glued together from multiple sources.
                const gop = try buckets.getOrPut(s);
                if (!gop.found_existing) {
                    const owned_key = try allocator.dupe(u8, s);
                    gop.key_ptr.* = owned_key;
                    gop.value_ptr.* = .{ .tokens = burst, .last_refill_ms = 0 };
                }
            }
        }

        return .{
            .allocator = allocator,
            .wildcard = has_wildcard,
            .rate_per_ms = rate / 1000.0,
            .burst = burst,
            .buckets = buckets,
        };
    }

    pub fn deinit(self: *Allowlist) void {
        if (!self.wildcard) {
            var it = self.buckets.keyIterator();
            while (it.next()) |key_ptr| {
                self.allocator.free(key_ptr.*);
            }
        }
        self.buckets.deinit();
    }

    pub fn isWildcard(self: *const Allowlist) bool {
        return self.wildcard;
    }

    pub fn admit(self: *Allowlist, sender_id: []const u8, now_ms: i64) Decision {
        const key = if (self.wildcard) wildcard_key else sender_id;
        const bucket = self.buckets.getPtr(key) orelse return .rejected_unauthorized;

        // Seed `last_refill_ms` on first contact so the bucket starts
        // full from the caller's clock rather than from epoch zero (a
        // cold allowlist handed a `now_ms` of e.g. 1_700_000_000_000
        // would otherwise refill to `burst` on the very next call,
        // defeating the burst cap).
        if (bucket.last_refill_ms == 0) {
            bucket.last_refill_ms = now_ms;
        } else if (now_ms > bucket.last_refill_ms) {
            const elapsed_ms: f64 = @floatFromInt(now_ms - bucket.last_refill_ms);
            bucket.tokens = @min(self.burst, bucket.tokens + elapsed_ms * self.rate_per_ms);
            bucket.last_refill_ms = now_ms;
        }

        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            return .allow;
        }
        return .rejected_rate_limited;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "allowlist: two distinct senders each get their own bucket" {
    const senders = [_][]const u8{ "alice", "bob" };
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders });
    defer al.deinit();

    try testing.expectEqual(Decision.allow, al.admit("alice", 1_000));
    try testing.expectEqual(Decision.allow, al.admit("bob", 1_000));
}

test "allowlist: same sender twice at the same instant is rate-limited" {
    const senders = [_][]const u8{"alice"};
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders, .rate_per_second = 1.0 });
    defer al.deinit();

    try testing.expectEqual(Decision.allow, al.admit("alice", 5_000));
    // Burst at rate 1.0 is ceil(4) = 4 — to actually see a rate-limit
    // we need to exhaust the burst before the second admit.
    try testing.expectEqual(Decision.allow, al.admit("alice", 5_000));
    try testing.expectEqual(Decision.allow, al.admit("alice", 5_000));
    try testing.expectEqual(Decision.allow, al.admit("alice", 5_000));
    try testing.expectEqual(Decision.rejected_rate_limited, al.admit("alice", 5_000));
}

test "allowlist: bucket refills after elapsed time" {
    const senders = [_][]const u8{"alice"};
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders, .rate_per_second = 1.0 });
    defer al.deinit();

    // Drain the burst (4 tokens at rate 1.0).
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expectEqual(Decision.allow, al.admit("alice", 10_000));
    }
    try testing.expectEqual(Decision.rejected_rate_limited, al.admit("alice", 10_000));
    // 1100ms later the bucket has ~1.1 tokens — admit once more.
    try testing.expectEqual(Decision.allow, al.admit("alice", 11_100));
}

test "allowlist: unknown sender is rejected" {
    const senders = [_][]const u8{"alice"};
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders });
    defer al.deinit();

    try testing.expectEqual(Decision.rejected_unauthorized, al.admit("mallory", 1_000));
}

test "allowlist: wildcard admits anyone into a shared bucket" {
    const senders = [_][]const u8{"*"};
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders, .rate_per_second = 1.0 });
    defer al.deinit();

    try testing.expect(al.isWildcard());
    // Shared bucket: burst of 4 total regardless of sender identity.
    try testing.expectEqual(Decision.allow, al.admit("anyone", 2_000));
    try testing.expectEqual(Decision.allow, al.admit("someone-else", 2_000));
    try testing.expectEqual(Decision.allow, al.admit("anyone", 2_000));
    try testing.expectEqual(Decision.allow, al.admit("anyone", 2_000));
    try testing.expectEqual(Decision.rejected_rate_limited, al.admit("anyone", 2_000));
}

test "allowlist: wildcard mixed with explicit entries is a config error" {
    const senders = [_][]const u8{ "*", "alice" };
    try testing.expectError(
        ConfigError.WildcardWithEntries,
        Allowlist.init(testing.allocator, .{ .senders = &senders }),
    );
}

test "allowlist: burst sizing at rate 2.0/s tolerates 8 in a row" {
    const senders = [_][]const u8{"alice"};
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders, .rate_per_second = 2.0 });
    defer al.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(Decision.allow, al.admit("alice", 100));
    }
    try testing.expectEqual(Decision.rejected_rate_limited, al.admit("alice", 100));
}

test "allowlist: duplicate sender entries collapse to one bucket" {
    const senders = [_][]const u8{ "alice", "alice" };
    var al = try Allowlist.init(testing.allocator, .{ .senders = &senders, .rate_per_second = 1.0 });
    defer al.deinit();
    // Only 4 burst tokens despite the duplicate listing.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expectEqual(Decision.allow, al.admit("alice", 1));
    }
    try testing.expectEqual(Decision.rejected_rate_limited, al.admit("alice", 1));
}
