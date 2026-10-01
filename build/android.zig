//! Android build entry: cross-compile the JNI `.so` and package a debug-signed APK (no Gradle).
const std = @import("std");

/// Bionic link stubs for `aarch64-linux-android` (matches common arm64 AVDs on Apple Silicon).
pub const android_api_level: u32 = 29;

pub const LibName = "sudoku_zig";
pub const ApkName = "sudoku.apk";
const OutDir = "zig-out/android";
const SoPath = "zig-out/lib/libsudoku_zig.so";
const BootstrapRoot = "src/android/bootstrap";
const ManifestPath = BootstrapRoot ++ "/AndroidManifest.xml";
const ResourcePath = BootstrapRoot ++ "/res";
const JavaSourceMain = BootstrapRoot ++ "/MainActivity.java";
const JavaSourceJni = BootstrapRoot ++ "/JniHost.java";

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
        const android_lib_fail = b.step("android-lib", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
        android_lib_fail.dependOn(&fail.step);
        const android_fail = b.step("android", "Build a debug-signed Android APK (arm64-v8a, no Gradle)");
        android_fail.dependOn(&fail.step);
        return android_fail;
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
    const android_lib_step = b.step("android-lib", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
    android_lib_step.dependOn(&install.step);

    const sdk_opt = b.option([]const u8, "sdk", "Android SDK root (default: $ANDROID_HOME or $ANDROID_SDK_ROOT)");
    const sdk_root = resolveSdkRoot(sdk_opt) orelse {
        const fail = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'error: Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.' >&2; exit 1",
        });
        fail.step.dependOn(&install.step);
        const step = b.step("android", "Build a debug-signed Android APK (arm64-v8a, no Gradle)");
        step.dependOn(&fail.step);
        return step;
    };

    const package_apk = b.addSystemCommand(&.{
        "bash",
        "scripts/android-package.sh",
        sdk_root,
        b.fmt("{d}", .{android_api_level}),
        OutDir,
        JavaSourceMain,
        JavaSourceJni,
        ManifestPath,
        ResourcePath,
        SoPath,
        ApkName,
    });
    package_apk.step.dependOn(&install.step);

    const android_step = b.step("android", "Build a debug-signed Android APK (arm64-v8a, no Gradle)");
    android_step.dependOn(&package_apk.step);
    return android_step;
}

fn resolveNdkRoot(override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (lookupEnvLiteral("ANDROID_NDK_HOME")) |p| return p;
    return lookupEnvLiteral("ANDROID_NDK_ROOT");
}

fn resolveSdkRoot(override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (lookupEnvLiteral("ANDROID_HOME")) |p| return p;
    return lookupEnvLiteral("ANDROID_SDK_ROOT");
}

fn lookupEnvLiteral(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const slice = std.mem.sliceTo(value, 0);
    if (slice.len == 0) return null;
    return slice;
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
