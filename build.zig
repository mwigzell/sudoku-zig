const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sudoku_mod = b.addModule("sudoku", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sudoku",
        .root_module = sudoku_mod,
    });
    b.installArtifact(exe);

    // run step
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the Sudoku game");
    run_step.dependOn(&run_cmd.step);

    // test step — thin root (tests.zig) imports all source modules so their
    // co-located `test` blocks are discovered by Zig 0.17's addTest.
    // Co-location follows Ziglings 105 style: tests live in the same file as the code.
    {
        const test_mod = b.addModule("sudoku_test", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        });

        const check = b.addTest(.{
            .root_module = test_mod,
        });
        const test_run = b.addRunArtifact(check);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&test_run.step);
    }
}
