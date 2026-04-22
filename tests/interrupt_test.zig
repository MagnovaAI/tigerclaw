//! Integration tests for the cooperative interrupt flag.
//!
//! These exercise the cross-thread signalling contract the react loop
//! will rely on: one thread requests an interrupt while another is
//! polling at a safe point, and the poller must observe the request
//! without coordination beyond the atomic itself.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const testing = std.testing;

const interrupt_mod = tigerclaw.harness.interrupt;

test "interrupt: signaller and poller communicate across threads" {
    var flag = interrupt_mod.Interrupt{};

    const Poller = struct {
        fn run(ptr: *interrupt_mod.Interrupt, observed: *std.atomic.Value(bool)) void {
            // Spin at the resolution a real consumer would use: between
            // each "safe point", check the flag. The test loop is
            // bounded so a bug never hangs CI.
            var attempts: u32 = 0;
            while (attempts < 1_000_000) : (attempts += 1) {
                if (ptr.isRequested()) {
                    observed.store(true, .release);
                    return;
                }
                std.Thread.yield() catch {};
            }
        }
    };

    var observed = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, Poller.run, .{ &flag, &observed });

    // Signal right away. The poller is bounded, so whether or not the
    // poller has entered its loop yet, the request is observed before
    // the loop's iteration cap runs out.
    flag.request();
    th.join();

    try testing.expect(observed.load(.acquire));
}

test "interrupt: clear lets a session be reused after cancellation" {
    var flag = interrupt_mod.Interrupt{};
    flag.request();
    try testing.expectError(error.Interrupted, flag.check());

    // Simulate the harness acknowledging the interrupt before starting
    // a fresh turn — the flag must not carry over.
    flag.clear();
    try flag.check();
    try testing.expect(!flag.isRequested());
}

test "interrupt: many signals collapse to one observable state" {
    var flag = interrupt_mod.Interrupt{};

    const Spammer = struct {
        fn run(ptr: *interrupt_mod.Interrupt) void {
            var i: u32 = 0;
            while (i < 10_000) : (i += 1) ptr.request();
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Spammer.run, .{&flag});
    }
    for (threads) |t| t.join();

    try testing.expect(flag.isRequested());
}
