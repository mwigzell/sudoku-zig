const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Executable ---
    const exe_mod = b.addModule("sudoku", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "sudoku",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // clean step — remove local cache so subsequent builds are fresh
    const rm_cache = b.addSystemCommand(&.{ "rm", "-rf", "./.zig-cache" });
    const clean_step = b.step("clean", "Remove the local .zig-cache");
    clean_step.dependOn(&rm_cache.step);

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
        .link_libc = true,
    });

    // Optional -Dtest-filter to filter tests at compile time (avoids server-mode CLI issues)
    const filter_opt = b.option([]const u8, "test-filter", "Filter tests by name");
    const filters: []const []const u8 = if (filter_opt) |f|
        b.dupeStrings(&[_][]const u8{ f })
    else &[_][]const u8{};


    const check = b.addTest(.{
        .name = "test",
        .root_module = test_mod,
        .use_llvm = true,
        .filters = filters,
    });

    // Run the compiled test binary via addRunArtifact (server-mode IPC).
    // Works because no tests touch std.testing.io — InMemoryOutput is used for I/O tests.
    const run_tests = b.addRunArtifact(check);
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
