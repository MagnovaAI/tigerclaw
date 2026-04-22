const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The `tigerclaw` library module is built once and reused by the
    // executable, the unit-test runner, and every integration test. This
    // lets `tests/*_test.zig` say `@import("tigerclaw")` to reach the
    // library surface.
    const tigerclaw_mod = b.addModule("tigerclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    // is a tests/<name>.zig file compiled as its own test binary with the
    // `tigerclaw` module available for import.
    const integration_tests: []const []const u8 = &.{
        "settings_schema_test",
        "settings_env_override_test",
        "settings_change_detector_test",
        "trace_roundtrip_test",
        "trace_diff_test",
        "trace_redact_test",
        "vcr_roundtrip_test",
        "vcr_provider_contract_test",
        "token_estimator_test",
        "provider_contract_test",
        "routing_test",
        "reliability_retry_test",
        "circuit_breaker_test",
        "fault_transport_test",
        "fault_policy_test",
        "harness_test",
        "session_test",
        "budget_test",
        "interrupt_test",
        "mode_policy_test",
        "bench_guards_test",
        "sandbox_fs_test",
        "sandbox_exec_test",
        "permissions_test",
        "cost_ledger_test",
        "diagnostics_buffer_test",
        "e2e_run_with_mock_test",
        "react_loop_test",
        "prompt_cache_test",
        "context_window_test",
        "compaction_test",
        "tool_contract_test",
        "tool_justification_lint_test",
        "scenario_loader_test",
        "bench_concurrency_test",
        "hash_guard_test",
        "eval_golden_test",
        "eval_bless_test",
        "eval_judge_test",
        "assertion_freeze_test",
        "witness_cardinality_test",
        "e2e_replay_roundtrip_test",
        "e2e_bench_full_run_test",
        "e2e_eval_full_cycle_test",
        "e2e_gateway_roundtrip_test",
    };
    for (integration_tests) |name| {
        const rel = b.fmt("tests/{s}.zig", .{name});
        const mod = b.createModule(.{
            .root_source_file = b.path(rel),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("tigerclaw", tigerclaw_mod);
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
