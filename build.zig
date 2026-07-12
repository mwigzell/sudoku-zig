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
    });
    const test_run = b.addRunArtifact(check);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}
