//! Integration: fault_policy windowing is reachable via the llm surface
//! and degrades predictably under load.

const std = @import("std");
const tigerclaw = @import("tigerclaw");
const reliability = tigerclaw.llm.reliability;

const testing = std.testing;

test "fault_policy: tight quota denies extras within window, resets on window flip" {
    var p = reliability.FaultPolicy.init(2, std.time.ns_per_s);

    try p.check(0);
    try p.check(std.time.ns_per_ms * 100);
    try testing.expectError(error.QuotaExceeded, p.check(std.time.ns_per_ms * 200));

    try p.check(std.time.ns_per_s + 1);
    try p.check(std.time.ns_per_s + 100);
    try testing.expectError(error.QuotaExceeded, p.check(std.time.ns_per_s + 500));
}
