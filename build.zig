const std = @import("std");

fn hasToken(spec: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "all")) return true;
        if (std.mem.eql(u8, tok, token)) return true;
    }
    return false;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dextensions=<csv>. "all" enables every known extension; "" enables
    // none. Default ships every extension so plain `zig build` matches
    // the historical behaviour.
    const extensions_spec = b.option(
        []const u8,
        "extensions",
        "Comma-separated provider extensions to compile in (anthropic,openai,bedrock,openrouter,all). Default: all.",
    ) orelse "anthropic,openai,bedrock,openrouter,telegram";

    const enable_anthropic = hasToken(extensions_spec, "anthropic");
    const enable_openai = hasToken(extensions_spec, "openai");
    const enable_bedrock = hasToken(extensions_spec, "bedrock");
    const enable_openrouter = hasToken(extensions_spec, "openrouter");
    const enable_telegram = hasToken(extensions_spec, "telegram");

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_anthropic", enable_anthropic);
    build_options.addOption(bool, "enable_openai", enable_openai);
    build_options.addOption(bool, "enable_bedrock", enable_bedrock);
    build_options.addOption(bool, "enable_openrouter", enable_openrouter);
    build_options.addOption(bool, "enable_telegram", enable_telegram);
    const build_options_mod = build_options.createModule();

    // Named modules carved out of the `tigerclaw` source tree so that
    // extension code (in its own module) can reach exactly these three
    // surfaces and nothing else. The Amendment A allowlist is enforced
    // by the explicit `addImport` chain below.
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/types/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const llm_provider_mod = b.addModule("llm_provider", .{
        .root_source_file = b.path("src/llm/provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    llm_provider_mod.addImport("types", types_mod);

    const llm_transport_mod = b.addModule("llm_transport", .{
        .root_source_file = b.path("src/llm/transport/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const channels_spec_mod = b.addModule("channels_spec", .{
        .root_source_file = b.path("src/channels/spec.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The `tigerclaw` library module is built once and reused by the
    // executable, the unit-test runner, and every integration test. This
    // lets `tests/*_test.zig` say `@import("tigerclaw")` to reach the
    // library surface.
    const tigerclaw_mod = b.addModule("tigerclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tigerclaw_mod.addImport("types", types_mod);
    tigerclaw_mod.addImport("llm_provider", llm_provider_mod);
    tigerclaw_mod.addImport("llm_transport", llm_transport_mod);
    tigerclaw_mod.addImport("channels_spec", channels_spec_mod);
    tigerclaw_mod.addImport("build_options", build_options_mod);

    var provider_anthropic_mod: ?*std.Build.Module = null;
    var provider_openai_mod: ?*std.Build.Module = null;
    var provider_bedrock_mod: ?*std.Build.Module = null;
    var provider_openrouter_mod: ?*std.Build.Module = null;
    var channel_telegram_mod: ?*std.Build.Module = null;
    if (enable_anthropic) {
        const ext = b.addModule("provider_anthropic", .{
            .root_source_file = b.path("extensions/providers-anthropic/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext.addImport("types", types_mod);
        ext.addImport("llm_provider", llm_provider_mod);
        ext.addImport("llm_transport", llm_transport_mod);
        tigerclaw_mod.addImport("provider_anthropic", ext);
        provider_anthropic_mod = ext;
    }
    if (enable_openai) {
        const ext = b.addModule("provider_openai", .{
            .root_source_file = b.path("extensions/providers-openai/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext.addImport("types", types_mod);
        ext.addImport("llm_provider", llm_provider_mod);
        ext.addImport("llm_transport", llm_transport_mod);
        tigerclaw_mod.addImport("provider_openai", ext);
        provider_openai_mod = ext;
    }
    if (enable_bedrock) {
        const ext = b.addModule("provider_bedrock", .{
            .root_source_file = b.path("extensions/providers-bedrock/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext.addImport("types", types_mod);
        ext.addImport("llm_provider", llm_provider_mod);
        tigerclaw_mod.addImport("provider_bedrock", ext);
        provider_bedrock_mod = ext;
    }
    if (enable_openrouter) {
        const ext = b.addModule("provider_openrouter", .{
            .root_source_file = b.path("extensions/providers-openrouter/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext.addImport("types", types_mod);
        ext.addImport("llm_provider", llm_provider_mod);
        ext.addImport("llm_transport", llm_transport_mod);
        tigerclaw_mod.addImport("provider_openrouter", ext);
        provider_openrouter_mod = ext;
    }
    if (enable_telegram) {
        const ext = b.addModule("channel_telegram", .{
            .root_source_file = b.path("extensions/channels-telegram/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext.addImport("build_options", build_options_mod);
        ext.addImport("channels_spec", channels_spec_mod);
        tigerclaw_mod.addImport("channel_telegram", ext);
        channel_telegram_mod = ext;
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("build_options", build_options_mod);
    exe_mod.addImport("types", types_mod);
    exe_mod.addImport("llm_provider", llm_provider_mod);
    exe_mod.addImport("llm_transport", llm_transport_mod);
    exe_mod.addImport("channels_spec", channels_spec_mod);
    if (provider_anthropic_mod) |m| exe_mod.addImport("provider_anthropic", m);
    if (provider_openai_mod) |m| exe_mod.addImport("provider_openai", m);
    if (provider_bedrock_mod) |m| exe_mod.addImport("provider_bedrock", m);
    if (provider_openrouter_mod) |m| exe_mod.addImport("provider_openrouter", m);
    if (channel_telegram_mod) |m| exe_mod.addImport("channel_telegram", m);
    const exe = b.addExecutable(.{
        .name = "tigerclaw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tigerclaw");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests (unit + integration)");

    // Unit tests: live at the bottom of source files, discovered via src/main.zig.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.addImport("build_options", build_options_mod);
    unit_mod.addImport("types", types_mod);
    unit_mod.addImport("llm_provider", llm_provider_mod);
    unit_mod.addImport("llm_transport", llm_transport_mod);
    unit_mod.addImport("channels_spec", channels_spec_mod);
    if (provider_anthropic_mod) |m| unit_mod.addImport("provider_anthropic", m);
    if (provider_openai_mod) |m| unit_mod.addImport("provider_openai", m);
    if (provider_bedrock_mod) |m| unit_mod.addImport("provider_bedrock", m);
    if (provider_openrouter_mod) |m| unit_mod.addImport("provider_openrouter", m);
    if (channel_telegram_mod) |m| unit_mod.addImport("channel_telegram", m);
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The three named modules (`types`, `llm_provider`, `llm_transport`)
    // own their own subtrees and are compiled in isolation; their unit
    // tests only run if we add dedicated test artifacts for them here.
    const types_tests = b.addTest(.{ .root_module = types_mod });
    test_step.dependOn(&b.addRunArtifact(types_tests).step);
    const llm_provider_tests = b.addTest(.{ .root_module = llm_provider_mod });
    test_step.dependOn(&b.addRunArtifact(llm_provider_tests).step);
    const llm_transport_tests = b.addTest(.{ .root_module = llm_transport_mod });
    test_step.dependOn(&b.addRunArtifact(llm_transport_tests).step);
    const channels_spec_tests = b.addTest(.{ .root_module = channels_spec_mod });
    test_step.dependOn(&b.addRunArtifact(channels_spec_tests).step);

    if (provider_anthropic_mod) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (provider_openai_mod) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (provider_bedrock_mod) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (provider_openrouter_mod) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (channel_telegram_mod) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

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
        mod.addImport("build_options", build_options_mod);
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
