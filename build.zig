const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tigerclaw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tigerclaw");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests (unit + integration)");

    // Unit tests: live at the bottom of source files, discovered via src/main.zig.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration / contract / e2e tests: each entry in `integration_tests`
    // is a tests/<name>_test.zig file compiled as its own test binary.
    // When adding a new integration test, add its filename (sans .zig) here.
    const integration_tests: []const []const u8 = &.{};
    for (integration_tests) |name| {
        const rel = b.fmt("tests/{s}.zig", .{name});
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(rel),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
