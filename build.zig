const std = @import("std");
const android_build = @import("build/android.zig");
const version = @import("src/core/version.zig");

pub fn build(b: *std.Build) void {
    const android_version_code: u32 = @as(u32, version.major) * 10_000 + @as(u32, version.minor) * 100 + @as(u32, version.patch);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Parity window (ADR-0022 §3) ---
    // Parity compares the front ends against each other, so the first arm of a contract change is
    // red on its own. An issue may declare a window: its steps run the gate with the check omitted,
    // named by this flag and validated against the tracker; the steps after it run plain `verify`.
    const Parity = enum { on, off };
    const parity = b.option(Parity, "parity", "Cross-front-end parity check: on (default), or off inside a declared parity window") orelse .on;
    const parity_off_issue = b.option(u32, "parity-off-issue", "The open issue whose declared window turns the parity check off");
    const parity_off = parity == .off;
    // The guard reads the number as text; a missing one is its first refusal, not a build panic.
    const parity_off_arg = if (parity_off_issue) |n| b.fmt("{d}", .{n}) else "";
    // The environment variable that tells the parity runners which issue opened the window.
    const PARITY_OFF_ENV = "SUDOKU_PARITY_OFF";

    const gen_build_info = b.addSystemCommand(&.{ "bash", "scripts/gen-build-info.sh" });
    // --- Executable ---
    const exe_mod = b.addModule("sudoku", .{
        .root_source_file = b.path("src/entry_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "sudoku",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    exe.step.dependOn(&gen_build_info.step);
    // WASM: emit before native compile (@embedFile is parse-time).
    const WASM_OUT = "src/wasm/artifacts/artifact.wasm";

    // --export forces the step symbol into the wasm export table (wasm-ld);
    // `export fn` alone is a no-op on this toolchain snapshot.
    const wasm_emit = b.addSystemCommand(&.{
        "zig",                          "build-exe",                 "src/entry_wasm.zig",
        "-target",                      "wasm32-freestanding",       "-femit-bin=" ++ WASM_OUT,
        "--export=init",                "--export=exec",             "--export=getLegend",
        "--export=getConfig",           "--export=getState",         "--export=toSaveFormat",
        "--export=flowRead",            "--export=flowFail",         "--export=toPuzzle",
        "--export=bootstrapHostConfig", "--export=generatePuzzle",   "--export=requestGenAbort",
        "--export=getAbout",            "--export=outPtr",           "--export=flowStart",
        "--export=flowNext",            "--export=setHostBuildInfo", "--export=commandStart",
        "--export=getGenText",          "--export=getCoreText",      "--export=logEnabled",
        "--export=getConfigTable",
    });
    const mkdir_artifacts = b.addSystemCommand(&.{ "mkdir", "-p", "src/wasm/artifacts" });
    wasm_emit.step.dependOn(&mkdir_artifacts.step);
    wasm_emit.step.dependOn(&gen_build_info.step);
    exe.step.dependOn(&wasm_emit.step);

    // clean step — remove cache, build, and coverage dirs for a truly fresh start
    const rm_all = b.addSystemCommand(&.{ "rm", "-rf", "./.zig-cache", "./zig-out", "./kcov-out" });
    const clean_step = b.step("clean", "Remove .zig-cache, zig-out, kcov-out");
    clean_step.dependOn(&rm_all.step);

    // run step — passthru: `zig build run -- -r web` (0.17; see docs/zig-testing.md)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the Sudoku game");
    run_step.dependOn(&run_cmd.step);

    const run_web = b.addRunArtifact(exe);
    run_web.addArgs(&.{ "-r", "web" });
    const web_step = b.step("web", "Serve embedded Sudoku web UI");
    web_step.dependOn(&run_web.step);

    // JS glue contract test for the served web page (command-in → full-text-out over the wasm import table).
    // Every wasm suite under src/wasm/ is discovered by node's test runner, so a new
    // `*.test.mjs` runs without editing a list here.
    const glue = b.addSystemCommand(&.{ "node", "--test", "src/wasm/" });
    const glue_step = b.step("glue", "Run the JS glue contract test (node)");
    glue_step.dependOn(&glue.step);
    glue.step.dependOn(&wasm_emit.step); // node test reads the emitted artifact — must run after wasm_emit

    // The sandcastle harness decides which step a run performs and when it must stop, so
    // a broken harness has to fail the gate rather than the next run.
    const sandcastle_test = b.addSystemCommand(&.{ "npm", "run", "sandcastle:test" });
    const sandcastle_test_step = b.step("sandcastle-test", "Run the sandcastle harness tests (node)");
    sandcastle_test_step.dependOn(&sandcastle_test.step);

    // Nothing typechecks .mts at run time, so the gate asks tsc; a typed harness is proof of its shape.
    const typecheck = b.addSystemCommand(&.{ "npm", "run", "typecheck" });
    const typecheck_step = b.step("typecheck", "Typecheck the sandcastle harness (tsc --noEmit)");
    typecheck_step.dependOn(&typecheck.step);

    // --- Tests ---
    // entry_native.zig transitively imports the domain modules; addTest discovers every co-located `test {}`
    // block via Zig's import-graph discovery.
    const test_mod = b.addModule("sudoku_test", .{
        .root_source_file = b.path("src/entry_native.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Optional -Dtest-filter to filter tests at compile time (avoids server-mode CLI issues)
    const filter_opt = b.option([]const u8, "test-filter", "Filter tests by name");
    const filters: []const []const u8 = if (filter_opt) |f|
        b.dupeStrings(&[_][]const u8{f})
    else
        &[_][]const u8{};

    const check = b.addTest(.{
        .name = "test",
        .root_module = test_mod,
        .use_llvm = true,
        .filters = filters,
    });
    check.step.dependOn(&wasm_emit.step);
    check.step.dependOn(&gen_build_info.step);

    // Run the compiled test binary via addRunArtifact (server-mode IPC).
    // Tests needing fake I/O use std.testing.io (in-process fake); server-mode IPC accommodates that.
    const run_tests = b.addRunArtifact(check);
    // Discovery includes the parity suite, which compares against the transcripts the native tests write.
    glue.step.dependOn(&run_tests.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // IDE "Debug Test" (vscode-zig) → zig-out/bin/debug-unit-tests
    const install_debug = b.addInstallArtifact(check, .{
        .dest_sub_path = "debug-unit-tests",
    });
    const debug_test_step = b.step("debug-test", "Build test binary for IDE debugging");
    debug_test_step.dependOn(&install_debug.step);

    // code coverage
    const cov_step = b.step("cov", "Run tests under kcov");
    const kcov = b.addSystemCommand(&.{
        "kcov",
        "--include-path",
        "src",
        "kcov-out",
    });
    kcov.addArtifactArg(check); // compiled test artifact
    cov_step.dependOn(&kcov.step);

    // JSON summary from the collected run — report-only, do not re-execute tests.
    const kcov_sum = b.addSystemCommand(&.{
        "kcov",
        "--dump-summary",
        "--report-only",
        "--include-path",
        "src",
        "kcov-out",
    });
    kcov_sum.addArtifactArg(check);
    kcov_sum.step.dependOn(&kcov.step);
    cov_step.dependOn(&kcov_sum.step);

    // verify stays report-only; plain cov also opens the browser on demand.
    // Opener chain matches serve.openBrowser: $BROWSER → generic → vivaldi last.
    const open_cov_script: []const u8 = switch (@import("builtin").os.tag) {
        .macos =>
        \\report="kcov-out/test/index.html"
        \\if [ -n "$BROWSER" ]; then $BROWSER "$report" && exit 0; fi
        \\open "$report" && exit 0
        \\open -a Vivaldi "$report" && exit 0
        \\exit 1
        ,
        else =>
        \\report="kcov-out/test/index.html"
        \\if [ -n "$BROWSER" ]; then $BROWSER "$report" && exit 0; fi
        \\xdg-open "$report" && exit 0
        \\vivaldi "$report" && exit 0
        \\exit 1
        ,
    };
    const open_cov = b.addSystemCommand(&.{ "sh", "-c", open_cov_script });
    open_cov.step.dependOn(&kcov_sum.step);
    // Report-only form: coverage collection + JSON, no browser.
    const cov_report_step = b.step("cov-report", "Run coverage and dump the JSON report");
    cov_report_step.dependOn(&kcov_sum.step);
    cov_step.dependOn(&open_cov.step);

    // --- Verify: the single command that gates a cycle ---
    // Tests + format check + coverage run together so the gate can't be
    // shadowed by task-local checklists (handoffs, TDD skill gates).
    const fmt_check = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src", "build.zig" });
    const standards_check = b.addSystemCommand(&.{ "env", "FORCE_COLOR=1", "bash", "scripts/verify-standards.sh" });
    const standards_step = b.step("standards", "Mechanical coding-standards check on branch diff");
    standards_step.dependOn(&standards_check.step);

    const parity_check = b.addSystemCommand(&.{ "bash", "scripts/verify-parity.sh" });
    const parity_step = b.step("parity", "Parity drift check: fixture, matrix and runners agree (the parity tests run in test and glue)");
    parity_step.dependOn(&parity_check.step);

    // Inside a window the check is omitted, so the guard is what still proves the window is live.
    const parity_window = b.addSystemCommand(&.{ "bash", "scripts/verify-parity-off.sh" });
    parity_window.addArg(parity_off_arg);

    const verify_run_step = b.step("verify-run", "Internal: exe + test + fmt + standards + parity + glue + coverage");
    verify_run_step.dependOn(&exe.step); // entry point must compile — test mode never analyzes main()
    verify_run_step.dependOn(&run_tests.step);
    verify_run_step.dependOn(&fmt_check.step);
    verify_run_step.dependOn(&standards_check.step);
    if (parity_off) {
        verify_run_step.dependOn(&parity_window.step);
    } else {
        verify_run_step.dependOn(&parity_check.step);
    }
    verify_run_step.dependOn(&glue.step);
    verify_run_step.dependOn(&sandcastle_test.step);
    verify_run_step.dependOn(&typecheck.step);
    verify_run_step.dependOn(&kcov_sum.step);

    // Untimed warm-up for the timing gate: compile every artifact verify-run needs, so the
    // measured run reports the suite's workload rather than whether the cache was cold.
    const verify_build_step = b.step("verify-build", "Internal: compile what verify-run uses (timing gate warm-up)");
    verify_build_step.dependOn(&exe.step); // exe pulls in wasm_emit and gen_build_info
    verify_build_step.dependOn(&check.step); // the test binary compiles without running

    const verify_gate = b.addSystemCommand(&.{ "bash", "scripts/verify-gate.sh" });
    const verify_step = b.step("verify", "Gate: verify-run + timing integrity (docs/verify-timing.json)");
    verify_step.dependOn(&verify_gate.step);

    // A window reaches the suites, not just the graph: `SUDOKU_PARITY_OFF` carries the issue number to
    // the parity runners, and the gate forwards it so its timed inner run omits the same check.
    if (parity_off) {
        if (parity_off_issue != null) {
            run_tests.setEnvironmentVariable(PARITY_OFF_ENV, parity_off_arg);
            glue.setEnvironmentVariable(PARITY_OFF_ENV, parity_off_arg);
            verify_gate.setEnvironmentVariable(PARITY_OFF_ENV, parity_off_arg);
        }
        run_tests.step.dependOn(&parity_window.step);
        glue.step.dependOn(&parity_window.step);
    }

    // Slow tests (generator properties, etc.) — delivery phase; not part of verify.
    const run_slow_tests = b.addSystemCommand(&.{
        "zig", "test", "src/entry_verify_slow.zig", "-lc", "--test-filter", "puzzle_gen live",
    });
    const run_e2e_tests = b.addSystemCommand(&.{
        "zig", "test", "src/entry_verify_slow.zig", "-lc", "--test-filter", "core_e2e",
    });
    const e2e_step = b.step("verify-slow-e2e", "Terminal e2e suite (core_e2e) alone, no generator");
    e2e_step.dependOn(&run_e2e_tests.step);
    const puzzle_gen_step = b.step("verify-slow-puzzle-gen", "Live generator properties (puzzle_gen live) alone, no e2e");
    puzzle_gen_step.dependOn(&run_slow_tests.step);
    const verify_slow_run_step = b.step("verify-slow-run", "Internal: costly tests (puzzle_gen live, core_e2e)");
    verify_slow_run_step.dependOn(&run_slow_tests.step);
    verify_slow_run_step.dependOn(&run_e2e_tests.step);

    const verify_slow_gate = b.addSystemCommand(&.{ "bash", "scripts/verify-slow-gate.sh" });
    const verify_slow_step = b.step("verify-slow", "Slow gate: verify-slow-run + timing (docs/verify-slow-timing.json)");
    verify_slow_step.dependOn(&verify_slow_gate.step);

    // The push boundary: every lane a push must prove, cheapest first, in one command so a push
    // cannot be assembled from whichever gates a session remembered. `-- --lanes` prints the table.
    const push_gate = b.addSystemCommand(&.{ "bash", "scripts/push-gate.sh" });
    push_gate.addPassthruArgs();
    push_gate.has_side_effects = true;
    const push_gate_step = b.step("push-gate", "Push gate: verify, verify-slow and the full device suite, cheapest first");
    push_gate_step.dependOn(&push_gate.step);

    _ = android_build.addAndroidStep(b, .{
        .wasm_emit = &wasm_emit.step,
        .gen_build_info = &gen_build_info.step,
        .version_name = version.string,
        .version_code = android_version_code,
        .test_filter = filter_opt,
    });
}
