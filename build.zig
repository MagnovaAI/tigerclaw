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
        "Comma-separated extensions to compile in (anthropic,openai,bedrock,openrouter,telegram,memory,all). Default: all.",
    ) orelse "anthropic,openai,bedrock,openrouter,telegram,memory";

    const enable_anthropic = hasToken(extensions_spec, "anthropic");
    const enable_openai = hasToken(extensions_spec, "openai");
    const enable_bedrock = hasToken(extensions_spec, "bedrock");
    const enable_openrouter = hasToken(extensions_spec, "openrouter");
    const enable_telegram = hasToken(extensions_spec, "telegram");
    const enable_memory = hasToken(extensions_spec, "memory");

    // CalVer — YYYY.MM.DD. Release pipelines override with
    // `-Dversion=2026.04.11`; local dev builds derive it from the
    // current date so `tigerclaw gateway` shows something useful.
    const default_version = calverToday(b.allocator) catch @panic("failed to derive CalVer version");
    const requested_version = b.option(
        []const u8,
        "version",
        "Zero-padded CalVer version string embedded in the binary (default: today)",
    ) orelse default_version;
    if (!isCalVer(requested_version)) {
        @panic("-Dversion must use zero-padded CalVer YYYY.MM.DD");
    }
    const app_version = requested_version;

    // Short git SHA for the working tree. Release pipelines pass
    // `-Dcommit=769908e`; local dev builds read `.git/HEAD` directly
    // via a small helper so the banner shows the live commit without
    // requiring `git` on PATH.
    const default_commit = gitShortSha(b.allocator) orelse "dev";
    const app_commit = b.option(
        []const u8,
        "commit",
        "Short git SHA embedded in the binary (default: HEAD)",
    ) orelse default_commit;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "commit", app_commit);
    build_options.addOption(bool, "enable_anthropic", enable_anthropic);
    build_options.addOption(bool, "enable_openai", enable_openai);
    build_options.addOption(bool, "enable_bedrock", enable_bedrock);
    build_options.addOption(bool, "enable_openrouter", enable_openrouter);
    build_options.addOption(bool, "enable_telegram", enable_telegram);
    build_options.addOption(bool, "enable_memory", enable_memory);
    const build_options_mod = build_options.createModule();

    // Extension ABI allowlist (Amendment A / architecture v3).
    //
    // Extensions live in their own module graph and may only reach the
    // tigerclaw core via the named modules declared below. Nothing in
    // `src/` is importable from extension code without going through
    // one of these surfaces. Enforcement is structural — each extension
    // is `b.addModule(...)` with its own source root, and the only
    // `.addImport(...)` calls it ever sees are the ones in this file.
    //
    // Current allowlist (keep this list in lockstep with the blocks
    // further down in this file):
    //   - types           — canonical struct definitions
    //   - llm_provider    — provider vtable (for provider-* plugs)
    //   - llm_transport   — HTTP + SSE transport helpers
    //   - channels_spec   — channel vtable (for channel-* plugs)
    //   - memory_spec     — session-store vtable (for memory-* plugs)
    //   - build_options   — compile-time feature flags
    //
    // New surface? Add it here AND in the extension's addImport block,
    // AND update this comment. Adding an ad-hoc `@import("../../src/x.zig")`
    // from an extension is not a shortcut — it breaks the module graph
    // and the build won't let you.
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/types/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const errors_mod = b.addModule("errors", .{
        .root_source_file = b.path("src/errors.zig"),
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

    const memory_spec_mod = b.addModule("memory_spec", .{
        .root_source_file = b.path("src/memory/spec.zig"),
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
    tigerclaw_mod.addImport("memory_spec", memory_spec_mod);
    tigerclaw_mod.addImport("build_options", build_options_mod);
    tigerclaw_mod.addImport("errors", errors_mod);
    // Core SQLite — instances, sessions, and the production
    // SessionStore all live in the same database. Linked
    // unconditionally because none of these features are optional
    // plugs.
    tigerclaw_mod.link_libc = true;
    tigerclaw_mod.linkSystemLibrary("sqlite3", .{});

    var provider_anthropic_mod: ?*std.Build.Module = null;
    var provider_openai_mod: ?*std.Build.Module = null;
    var provider_bedrock_mod: ?*std.Build.Module = null;
    var provider_openrouter_mod: ?*std.Build.Module = null;
    var channel_telegram_mod: ?*std.Build.Module = null;
    var memory_tigerclaw_mod: ?*std.Build.Module = null;
    if (enable_anthropic) {
        const ext = b.addModule("provider_anthropic", .{
            .root_source_file = b.path("extensions/provider-anthropic/root.zig"),
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
            .root_source_file = b.path("extensions/provider-openai/root.zig"),
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
            .root_source_file = b.path("extensions/provider-bedrock/root.zig"),
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
            .root_source_file = b.path("extensions/provider-openrouter/root.zig"),
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
            .root_source_file = b.path("extensions/channel-telegram/root.zig"),
            .target = target,
            .optimize = optimize,
            // Bot.nowMs uses std.c.clock_gettime now that
            // std.time.milliTimestamp is gone in 0.16.
            .link_libc = true,
        });
        ext.addImport("build_options", build_options_mod);
        ext.addImport("channels_spec", channels_spec_mod);
        tigerclaw_mod.addImport("channel_telegram", ext);
        channel_telegram_mod = ext;
    }
    if (enable_memory) {
        const ext = b.addModule("memory_tigerclaw", .{
            .root_source_file = b.path("extensions/memory-tigerclaw/root.zig"),
            .target = target,
            .optimize = optimize,
            // sqlite3 is reached via @cImport; libc provides the headers.
            .link_libc = true,
        });
        ext.addImport("memory_spec", memory_spec_mod);
        ext.linkSystemLibrary("sqlite3", .{});
        tigerclaw_mod.addImport("memory_tigerclaw", ext);
        memory_tigerclaw_mod = ext;
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Daemon plumbing reaches std.c.{getpid, clock_gettime, SIG};
        // Linux/musl needs the dependency declared explicitly.
        .link_libc = true,
    });
    exe_mod.addImport("build_options", build_options_mod);
    exe_mod.addImport("types", types_mod);
    exe_mod.addImport("llm_provider", llm_provider_mod);
    exe_mod.addImport("llm_transport", llm_transport_mod);
    exe_mod.addImport("channels_spec", channels_spec_mod);
    exe_mod.addImport("memory_spec", memory_spec_mod);
    exe_mod.addImport("errors", errors_mod);
    if (provider_anthropic_mod) |m| exe_mod.addImport("provider_anthropic", m);
    if (provider_openai_mod) |m| exe_mod.addImport("provider_openai", m);
    if (provider_bedrock_mod) |m| exe_mod.addImport("provider_bedrock", m);
    if (provider_openrouter_mod) |m| exe_mod.addImport("provider_openrouter", m);
    if (channel_telegram_mod) |m| exe_mod.addImport("channel_telegram", m);
    if (memory_tigerclaw_mod) |m| {
        exe_mod.addImport("memory_tigerclaw", m);
    }
    // Core SQLite for the executable; same rationale as the lib
    // module — sessions / instances / memory all live in one db.
    exe_mod.linkSystemLibrary("sqlite3", .{});

    // Vaxis TUI dependency
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    // Library consumers (`@import("tigerclaw")` from tests) reach
    // the TUI widgets re-exported from \`src/root.zig\`, which
    // transitively @import vaxis. Give the library module the
    // vaxis import too so those paths resolve.
    tigerclaw_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

    // PCRE static library: compiled from vendored C sources. Koino's
    // CommonMark parser (see packages/koino) needs a Perl-compatible
    // regex engine; rather than depending on the system libpcre we
    // build it in-tree so builds stay hermetic.
    const pcre_lib = b.addLibrary(.{
        .name = "pcre",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    pcre_lib.root_module.addIncludePath(b.path("packages/libpcre/pcre"));
    pcre_lib.root_module.link_libc = true;
    pcre_lib.root_module.addCSourceFiles(.{
        .root = b.path("packages/libpcre/pcre"),
        .flags = &.{
            "-Wno-implicit-function-declaration",
            "-DHAVE_CONFIG_H",
        },
        .files = &.{
            "pcre_byte_order.c",  "pcre_chartables.c", "pcre_compile.c",
            "pcre_config.c",      "pcre_dfa_exec.c",   "pcre_exec.c",
            "pcre_fullinfo.c",    "pcre_get.c",        "pcre_globals.c",
            "pcre_jit_compile.c", "pcre_maketables.c", "pcre_newline.c",
            "pcre_ord2utf8.c",    "pcre_refcount.c",   "pcre_string_utils.c",
            "pcre_study.c",       "pcre_tables.c",     "pcre_ucd.c",
            "pcre_valid_utf8.c",  "pcre_version.c",    "pcre_xclass.c",
        },
    });

    // libpcre.zig binding module.
    const libpcre_mod = b.addModule("libpcre", .{
        .root_source_file = b.path("packages/libpcre/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    libpcre_mod.linkLibrary(pcre_lib);
    libpcre_mod.addIncludePath(b.path("packages/libpcre/pcre"));

    // Koino CommonMark parser. We drop koino's HTML renderer and CLI
    // (see packages/koino/src/koino.zig) so the only external deps
    // are libpcre for regex and uucode for grapheme casing. uucode
    // is already wired further down as part of the context engine.
    const koino_mod = b.addModule("koino", .{
        .root_source_file = b.path("packages/koino/src/koino.zig"),
        .target = target,
        .optimize = optimize,
    });
    koino_mod.addImport("libpcre", libpcre_mod);
    // Reuse the uucode instance vaxis already configured — vaxis
    // selected a specific `fields` set at dependency time and
    // spawning a second uucode with a different set would double
    // the expensive generate step. The vaxis dependency re-exposes
    // its transitive uucode dep through its builder graph, so we
    // reach in and pull the module from vaxis's own build graph
    // rather than instantiating a fresh one.
    // Reuse the uucode module vaxis already built — we patched
    // koino's strings.zig to stop asking for `simple_lowercase_mapping`
    // (now ASCII-only via std.ascii.toLower), so its remaining uses
    // (`general_category`, etc.) all fit the default vaxis set.
    koino_mod.addImport("uucode", vaxis_dep.builder.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    }).module("uucode"));
    exe_mod.addImport("koino", koino_mod);
    // The library module re-exports the TUI namespace, which now
    // pulls in koino-backed markdown rendering (`src/tui/md.zig`).
    // External consumers reaching through `@import("tigerclaw")`
    // need koino on the module graph or the TUI imports fail to
    // resolve.
    tigerclaw_mod.addImport("koino", koino_mod);

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

    // Opt-in live smoke test for telegram. Hits the real Telegram API
    // via TIGERCLAW_TG_TOKEN; not part of `zig build test`.
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/live_telegram_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addImport("tigerclaw", tigerclaw_mod);
    smoke_mod.addImport("build_options", build_options_mod);
    const smoke_exe = b.addExecutable(.{
        .name = "smoke-telegram",
        .root_module = smoke_mod,
    });
    const run_smoke = b.addRunArtifact(smoke_exe);
    const smoke_step = b.step("smoke-telegram", "Run the live Telegram handshake smoke test");
    smoke_step.dependOn(&run_smoke.step);

    const test_step = b.step("test", "Run all tests (unit + integration)");

    // Unit tests: live at the bottom of source files, discovered via src/main.zig.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Same libc requirement as exe_mod — unit tests exercise the
        // same daemon code paths.
        .link_libc = true,
    });
    unit_mod.addImport("build_options", build_options_mod);
    unit_mod.addImport("types", types_mod);
    unit_mod.addImport("llm_provider", llm_provider_mod);
    unit_mod.addImport("llm_transport", llm_transport_mod);
    unit_mod.addImport("channels_spec", channels_spec_mod);
    unit_mod.addImport("memory_spec", memory_spec_mod);
    unit_mod.addImport("errors", errors_mod);
    unit_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    unit_mod.addImport("koino", koino_mod);
    if (provider_anthropic_mod) |m| unit_mod.addImport("provider_anthropic", m);
    if (provider_openai_mod) |m| unit_mod.addImport("provider_openai", m);
    if (provider_bedrock_mod) |m| unit_mod.addImport("provider_bedrock", m);
    if (provider_openrouter_mod) |m| unit_mod.addImport("provider_openrouter", m);
    if (channel_telegram_mod) |m| unit_mod.addImport("channel_telegram", m);
    if (memory_tigerclaw_mod) |m| {
        unit_mod.addImport("memory_tigerclaw", m);
    }
    // unit_tests reach the core db module via tigerclaw lib.
    unit_mod.linkSystemLibrary("sqlite3", .{});
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
    const memory_spec_tests = b.addTest(.{ .root_module = memory_spec_mod });
    test_step.dependOn(&b.addRunArtifact(memory_spec_tests).step);

    const clock_mod = b.addModule("clock", .{
        .root_source_file = b.path("src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });
    tigerclaw_mod.addImport("clock", clock_mod);
    exe_mod.addImport("clock", clock_mod);
    unit_mod.addImport("clock", clock_mod);
    const clock_tests = b.addTest(.{ .root_module = clock_mod });
    test_step.dependOn(&b.addRunArtifact(clock_tests).step);

    const ctx_types_mod = b.addModule("ctx_types", .{
        .root_source_file = b.path("src/context/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    // ctx_types references wire `types` for the structured
    // `ContentBlock` slice on `Section.blocks` / `IngestParams.blocks`.
    ctx_types_mod.addImport("types", types_mod);
    const ctx_types_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_types_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_types_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_types_test_mod.addImport("types", types_mod);
    const ctx_types_tests = b.addTest(.{ .root_module = ctx_types_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_types_tests).step);

    const context_mod = b.addModule("context", .{
        .root_source_file = b.path("src/context.zig"),
        .target = target,
        .optimize = optimize,
    });
    context_mod.addImport("clock", clock_mod);
    tigerclaw_mod.addImport("context", context_mod);
    exe_mod.addImport("context", context_mod);
    unit_mod.addImport("context", context_mod);
    const context_tests = b.addTest(.{ .root_module = context_mod });
    test_step.dependOn(&b.addRunArtifact(context_tests).step);

    const ctx_engine_mod = b.addModule("ctx_engine", .{
        .root_source_file = b.path("src/context/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_engine_mod.addImport("context", context_mod);
    ctx_engine_mod.addImport("types.zig", ctx_types_mod);
    ctx_engine_mod.addImport("errors", errors_mod);

    const ctx_engine_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_engine_vtable_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_engine_test_mod.addImport("ctx_engine", ctx_engine_mod);
    const ctx_engine_tests = b.addTest(.{ .root_module = ctx_engine_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_engine_tests).step);

    const ctx_assemble_mod = b.addModule("ctx_assemble", .{
        .root_source_file = b.path("src/context/assemble.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_assemble_mod.addImport("ctx_types", ctx_types_mod);
    const ctx_assemble_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_assemble_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_assemble_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_assemble_test_mod.addImport("ctx_assemble", ctx_assemble_mod);
    const ctx_assemble_tests = b.addTest(.{ .root_module = ctx_assemble_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_assemble_tests).step);

    const ctx_budget_property_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_budget_property_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_budget_property_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_budget_property_test_mod.addImport("ctx_assemble", ctx_assemble_mod);
    const ctx_budget_property_tests = b.addTest(.{ .root_module = ctx_budget_property_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_budget_property_tests).step);

    const ctx_registry_mod = b.addModule("ctx_registry", .{
        .root_source_file = b.path("src/context/registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_registry_mod.addImport("ctx_engine", ctx_engine_mod);
    const ctx_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_registry_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_registry_test_mod.addImport("ctx_engine", ctx_engine_mod);
    ctx_registry_test_mod.addImport("ctx_registry", ctx_registry_mod);
    const ctx_registry_tests = b.addTest(.{ .root_module = ctx_registry_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_registry_tests).step);

    const ctx_recall_mod = b.addModule("ctx_recall", .{
        .root_source_file = b.path("src/context/recall.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_recall_mod.addImport("ctx_types", ctx_types_mod);
    ctx_recall_mod.addImport("errors", errors_mod);
    const ctx_recall_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_recall_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_recall_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_recall_test_mod.addImport("ctx_recall", ctx_recall_mod);
    const ctx_recall_tests = b.addTest(.{ .root_module = ctx_recall_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_recall_tests).step);

    const ctx_compact_mod = b.addModule("ctx_compact", .{
        .root_source_file = b.path("src/context/compact.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctx_compact_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_compact_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_compact_test_mod.addImport("ctx_compact", ctx_compact_mod);
    const ctx_compact_tests = b.addTest(.{ .root_module = ctx_compact_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_compact_tests).step);

    const ctx_default_engine_mod = b.addModule("ctx_default_engine", .{
        .root_source_file = b.path("src/context/default_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_default_engine_mod.addImport("ctx_types", ctx_types_mod);
    ctx_default_engine_mod.addImport("ctx_engine", ctx_engine_mod);
    ctx_default_engine_mod.addImport("ctx_assemble", ctx_assemble_mod);
    ctx_default_engine_mod.addImport("ctx_compact", ctx_compact_mod);
    ctx_default_engine_mod.addImport("context", context_mod);
    ctx_default_engine_mod.addImport("errors", errors_mod);
    // Default engine persists structured ContentBlocks alongside the
    // flat-text view, so it needs the wire `types` module.
    ctx_default_engine_mod.addImport("types", types_mod);

    const ctx_root_mod = b.addModule("ctx_root", .{
        .root_source_file = b.path("src/context/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_root_mod.addImport("ctx_types", ctx_types_mod);
    ctx_root_mod.addImport("ctx_engine", ctx_engine_mod);
    ctx_root_mod.addImport("ctx_assemble", ctx_assemble_mod);
    ctx_root_mod.addImport("ctx_registry", ctx_registry_mod);
    ctx_root_mod.addImport("ctx_compact", ctx_compact_mod);
    ctx_root_mod.addImport("ctx_recall", ctx_recall_mod);
    ctx_root_mod.addImport("ctx_default_engine", ctx_default_engine_mod);
    tigerclaw_mod.addImport("ctx_root", ctx_root_mod);
    exe_mod.addImport("ctx_root", ctx_root_mod);
    unit_mod.addImport("ctx_root", ctx_root_mod);

    const ctx_default_engine_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_default_engine_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_default_engine_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_default_engine_test_mod.addImport("ctx_engine", ctx_engine_mod);
    ctx_default_engine_test_mod.addImport("ctx_default_engine", ctx_default_engine_mod);
    ctx_default_engine_test_mod.addImport("context", context_mod);
    ctx_default_engine_test_mod.addImport("clock", clock_mod);
    const ctx_default_engine_tests = b.addTest(.{ .root_module = ctx_default_engine_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_default_engine_tests).step);

    const ctx_engine_contract_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_engine_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_engine_contract_test_mod.addImport("ctx_types", ctx_types_mod);
    ctx_engine_contract_test_mod.addImport("ctx_engine", ctx_engine_mod);
    ctx_engine_contract_test_mod.addImport("ctx_default_engine", ctx_default_engine_mod);
    ctx_engine_contract_test_mod.addImport("context", context_mod);
    ctx_engine_contract_test_mod.addImport("clock", clock_mod);
    const ctx_engine_contract_tests = b.addTest(.{ .root_module = ctx_engine_contract_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_engine_contract_tests).step);

    const capabilities_mod = b.addModule("capabilities", .{
        .root_source_file = b.path("src/capabilities.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctx_caps_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/context_capabilities_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ctx_caps_test_mod.addImport("capabilities", capabilities_mod);
    const ctx_caps_tests = b.addTest(.{ .root_module = ctx_caps_test_mod });
    test_step.dependOn(&b.addRunArtifact(ctx_caps_tests).step);

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
    if (memory_tigerclaw_mod) |m| {
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
        "e2e_telegram_dispatch_test",
        "tui_conversation_test",
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
        // The TUI conversation test drives a vxfw widget directly,
        // so it needs vaxis as a peer import alongside tigerclaw.
        if (std.mem.eql(u8, name, "tui_conversation_test")) {
            mod.addImport("vaxis", vaxis_dep.module("vaxis"));
        }
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

/// Derive a CalVer string `YYYY.MM.DD` from the current wall clock.
/// Used as the default for `-Dversion`. Returns a slice allocated
/// on the build graph arena so the string outlives the build step.
fn calverToday(allocator: std.mem.Allocator) ![]const u8 {
    // Zig 0.16 removed std.time.timestamp; reach for libc directly.
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const epoch_secs: u64 = if (rc == 0) @intCast(@max(@as(i64, 0), ts.sec)) else 0;
    const day_secs: u64 = 86400;

    // Days since 1970-01-01 via Euclidean date math (civil_from_days).
    // Source: Howard Hinnant's "Ghost of Departed Proofs" Date
    // Algorithms — correct for every day in the Gregorian calendar.
    const days: i64 = @intCast(epoch_secs / day_secs);
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    const year_u: u64 = @intCast(@max(@as(i64, 0), year));
    return std.fmt.allocPrint(allocator, "{c}{c}{c}{c}.{c}{c}.{c}{c}", .{
        decimalDigit((year_u / 1000) % 10),
        decimalDigit((year_u / 100) % 10),
        decimalDigit((year_u / 10) % 10),
        decimalDigit(year_u % 10),
        decimalDigit(m / 10),
        decimalDigit(m % 10),
        decimalDigit(d / 10),
        decimalDigit(d % 10),
    });
}

fn isCalVer(value: []const u8) bool {
    if (value.len != "YYYY.MM.DD".len) return false;
    for (value, 0..) |ch, i| {
        switch (i) {
            4, 7 => if (ch != '.') return false,
            else => if (!std.ascii.isDigit(ch)) return false,
        }
    }

    const month = decimal2(value[5..7]);
    const day = decimal2(value[8..10]);
    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

fn decimal2(value: []const u8) u8 {
    std.debug.assert(value.len == 2);
    return (value[0] - '0') * 10 + (value[1] - '0');
}

fn decimalDigit(value: u64) u8 {
    std.debug.assert(value < 10);
    return @as(u8, '0') + @as(u8, @intCast(value));
}

/// Read the short (7-char) git SHA of the working-tree `HEAD` by
/// parsing `.git/HEAD` via libc fopen/fread. We do not shell out to
/// `git` so the build stays self-contained; we do not use the Zig
/// 0.16 std.Io.Dir layer either because build.zig runs before the
/// Io provider is wired. Returns null when the repo layout doesn't
/// match (tarball build, shallow clone without `.git`, etc.);
/// callers fall back to "dev".
fn gitShortSha(allocator: std.mem.Allocator) ?[]const u8 {
    const head_bytes = readSmallFile(allocator, ".git/HEAD") orelse return null;
    defer allocator.free(head_bytes);

    const trimmed = std.mem.trim(u8, head_bytes, " \t\r\n");

    // Two forms:
    //   (1) `ref: refs/heads/<branch>` — follow the ref to the SHA
    //   (2) `<40-char sha>`             — detached HEAD, use directly
    const ref_prefix = "ref: ";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const ref_path = trimmed[ref_prefix.len..];
        const full_path = std.fmt.allocPrint(allocator, ".git/{s}", .{ref_path}) catch return null;
        defer allocator.free(full_path);
        const ref_bytes = readSmallFile(allocator, full_path) orelse return null;
        defer allocator.free(ref_bytes);
        const sha_hex = std.mem.trim(u8, ref_bytes, " \t\r\n");
        if (sha_hex.len < 7) return null;
        return allocator.dupe(u8, sha_hex[0..7]) catch null;
    }

    if (trimmed.len < 7) return null;
    return allocator.dupe(u8, trimmed[0..7]) catch null;
}

/// Slurp a small text file via libc. Returns `null` on any failure;
/// callers treat that as "not a git repo" and fall back.
fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    // Build a NUL-terminated path for libc; fopen requires C strings.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 1 > path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const c_path: [*:0]const u8 = @ptrCast(&path_buf);

    const file = std.c.fopen(c_path, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    var buf: [1024]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len, file);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0..n]) catch null;
}
