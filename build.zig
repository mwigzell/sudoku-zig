const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Executable ---
    const exe_mod = b.addModule("sudoku", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sudoku",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // run step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the Sudoku game");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    // root.zig imports all sub-modules; addTest discovers every co-located `test {}`
    // block via Zig's import-graph discovery (Ziglings 105 style).
    const test_mod = b.addModule("sudoku_test", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check = b.addTest(.{
        .name = "test",
        .root_module = test_mod,
        .use_llvm = true
    });

    // Run the compiled test binary directly via addSystemCommand to avoid
    // Zig 0.17's default server-mode IPC (--listen=-) which hangs on x86_64.
    // /bin/sh -c "exec $0" passes through to running the ELF directly as $0.
    const run_tests = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        "exec $0",
    });
    run_tests.addArtifactArg(check);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

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

	// After collection, dump a JSON summary and tell the user where to look.
	const kcov_sum = b.addSystemCommand(&.{
		"kcov",
		"--dump-summary",
		"--include-path",
		"src",
		"kcov-out",
	});
	kcov_sum.addArtifactArg(check);
	cov_step.dependOn(&kcov_sum.step);

	// Auto-open coverage HTML in browser
	const open_cov = b.addSystemCommand(&.{
		"vivaldi",
		"kcov-out/test/index.html",
	});
	cov_step.dependOn(&open_cov.step);
}
