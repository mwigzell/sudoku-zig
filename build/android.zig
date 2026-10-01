//! Cross-compile `libsudoku_zig.so` (arm64-v8a) with the Android NDK — APK packaging is a later step.
const std = @import("std");

/// Bionic link stubs for `aarch64-linux-android` (matches common arm64 AVDs on Apple Silicon).
pub const android_api_level: u32 = 29;

pub const LibName = "sudoku_zig";

pub fn addAndroidStep(b: *std.Build, deps: struct {
    wasm_emit: *std.Build.Step,
    gen_build_info: *std.Build.Step,
}) *std.Build.Step {
    const ndk_opt = b.option([]const u8, "ndk", "Android NDK root (default: $ANDROID_NDK_HOME or $ANDROID_NDK_ROOT)");
    const ndk_root = resolveNdkRoot(ndk_opt) orelse {
        const fail = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'error: Android NDK not found. Set ANDROID_NDK_HOME or install NDK (Side by side) via SDK Manager.' >&2; exit 1",
        });
        const step = b.step("android", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
        step.dependOn(&fail.step);
        return step;
    };

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
        .android_api_level = android_api_level,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const sysroot = b.pathJoin(&.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        hostPrebuiltTag(),
        "sysroot",
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/android_shared.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{
            sysroot,
            "usr",
            "lib",
            "aarch64-linux-android",
            b.fmt("{d}", .{android_api_level}),
        }),
    });
    lib_mod.linkSystemLibrary("dl", .{});
    lib_mod.linkSystemLibrary("log", .{});

    const shared = b.addLibrary(.{
        .name = LibName,
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    shared.setLibCFile(bionicLibCFile(b, sysroot, android_api_level));
    shared.root_module.pic = true;
    shared.step.dependOn(deps.wasm_emit);
    shared.step.dependOn(deps.gen_build_info);

    const install = b.addInstallArtifact(shared, .{});
    const step = b.step("android", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
    step.dependOn(&install.step);
    return step;
}

fn resolveNdkRoot(override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (lookupEnv("ANDROID_NDK_HOME")) |p| return p;
    return lookupEnv("ANDROID_NDK_ROOT");
}

fn lookupEnv(name: []const u8) ?[]const u8 {
    var name_buf: [128]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const value = std.c.getenv(@ptrCast(&name_buf)) orelse return null;
    return std.mem.sliceTo(value, 0);
}

fn bionicLibCFile(b: *std.Build, sysroot: []const u8, api_level: u32) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    const contents = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/aarch64-linux-android
        \\crt_dir={s}/usr/lib/aarch64-linux-android/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, sysroot, api_level });
    return wf.add("android-bionic-libc.txt", contents);
}

fn hostPrebuiltTag() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @panic("unsupported host OS for Android NDK cross-compile"),
    };
}
