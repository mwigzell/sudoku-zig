//! Android build entry: cross-compile the JNI `.so` and package a debug-signed APK (no Gradle).
const std = @import("std");

/// Bionic link stubs for `aarch64-linux-android` (matches common arm64 AVDs on Apple Silicon).
pub const android_api_level: u32 = 29;

pub const LibName = "sudoku_zig";
pub const ApkName = "sudoku.apk";
pub const ReleaseApkName = "sudoku-release.apk";
const OutDir = "zig-out/android";
const SoPathDebug = "zig-out/lib/lib/libsudoku_zig.so";
const SoPathRelease = "zig-out/lib/lib/libsudoku_zig.so";
const BootstrapRoot = "src/android/bootstrap";
const ManifestPath = BootstrapRoot ++ "/AndroidManifest.xml";
const ResourcePath = BootstrapRoot ++ "/res";
const JavaSourceMain = BootstrapRoot ++ "/MainActivity.java";
const JavaSourceJni = BootstrapRoot ++ "/JniHost.java";
const JniHelpersC = "src/android/jni_helpers.c";

pub fn addAndroidStep(b: *std.Build, deps: struct {
    wasm_emit: *std.Build.Step,
    gen_build_info: *std.Build.Step,
    version_name: []const u8,
    version_code: u32,
}) *std.Build.Step {
    const ndk_opt = b.option([]const u8, "ndk", "Android NDK root (default: $ANDROID_NDK_HOME or $ANDROID_NDK_ROOT)");
    const ndk_root = resolveNdkRoot(b, ndk_opt) orelse {
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
    // Keep debug APK debug-friendly by default; callers can still override with -Doptimize.
    const optimize_debug = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });
    // Release APK native library is always built with release optimization.
    const optimize_release: std.builtin.OptimizeMode = .ReleaseSmall;

    const host_prebuilt = resolveHostPrebuiltTag(b, ndk_root);
    const sysroot = b.pathJoin(&.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        host_prebuilt,
        "sysroot",
    });

    const lib_mod_debug = b.createModule(.{
        .root_source_file = b.path("src/entry_android.zig"),
        .target = target,
        .optimize = optimize_debug,
        .link_libc = true,
    });
    lib_mod_debug.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{
            sysroot,
            "usr",
            "lib",
            "aarch64-linux-android",
            b.fmt("{d}", .{android_api_level}),
        }),
    });
    lib_mod_debug.linkSystemLibrary("dl", .{});
    lib_mod_debug.linkSystemLibrary("log", .{});

    const shared_debug = b.addLibrary(.{
        .name = LibName,
        .root_module = lib_mod_debug,
        .linkage = .dynamic,
    });
    shared_debug.root_module.addCSourceFile(.{
        .file = b.path(JniHelpersC),
    });
    shared_debug.setLibCFile(bionicLibCFile(b, sysroot, android_api_level));
    shared_debug.root_module.pic = true;
    shared_debug.step.dependOn(deps.wasm_emit);
    shared_debug.step.dependOn(deps.gen_build_info);

    const install_debug = b.addInstallArtifact(shared_debug, .{
        .dest_sub_path = "lib/libsudoku_zig.so",
    });
    const android_lib_step = b.step("android-lib", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
    android_lib_step.dependOn(&install_debug.step);

    const lib_mod_release = b.createModule(.{
        .root_source_file = b.path("src/entry_android.zig"),
        .target = target,
        .optimize = optimize_release,
        .link_libc = true,
    });
    lib_mod_release.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{
            sysroot,
            "usr",
            "lib",
            "aarch64-linux-android",
            b.fmt("{d}", .{android_api_level}),
        }),
    });
    lib_mod_release.linkSystemLibrary("dl", .{});
    lib_mod_release.linkSystemLibrary("log", .{});

    const shared_release = b.addLibrary(.{
        .name = LibName,
        .root_module = lib_mod_release,
        .linkage = .dynamic,
    });
    shared_release.root_module.addCSourceFile(.{
        .file = b.path(JniHelpersC),
    });
    shared_release.setLibCFile(bionicLibCFile(b, sysroot, android_api_level));
    shared_release.root_module.pic = true;
    shared_release.step.dependOn(deps.wasm_emit);
    shared_release.step.dependOn(deps.gen_build_info);

    const install_release = b.addInstallArtifact(shared_release, .{});

    const sdk_opt = b.option([]const u8, "sdk", "Android SDK root (default: $ANDROID_HOME or $ANDROID_SDK_ROOT)");
    const sdk_root = resolveSdkRoot(b, sdk_opt) orelse {
        const fail = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'error: Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.' >&2; exit 1",
        });
        fail.step.dependOn(&install_debug.step);
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
        SoPathDebug,
        ApkName,
        b.fmt("{d}", .{deps.version_code}),
        deps.version_name,
        "debug",
    });
    package_apk.step.dependOn(&install_debug.step);

    const android_step = b.step("android", "Build a debug-signed Android APK (arm64-v8a, no Gradle)");
    android_step.dependOn(&package_apk.step);

    const package_release_apk = b.addSystemCommand(&.{
        "bash",
        "scripts/android-package.sh",
        sdk_root,
        b.fmt("{d}", .{android_api_level}),
        OutDir,
        JavaSourceMain,
        JavaSourceJni,
        ManifestPath,
        ResourcePath,
        SoPathRelease,
        ReleaseApkName,
        b.fmt("{d}", .{deps.version_code}),
        deps.version_name,
        "release",
    });
    package_release_apk.step.dependOn(&install_release.step);

    const android_release_step = b.step("android-release", "Build a release-signed Android APK (arm64-v8a, no Gradle)");
    android_release_step.dependOn(&package_release_apk.step);
    return android_step;
}

fn resolveNdkRoot(b: *std.Build, override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (lookupEnvBuild(b, "ANDROID_NDK_HOME")) |p| return p;
    return lookupEnvBuild(b, "ANDROID_NDK_ROOT");
}

fn resolveSdkRoot(b: *std.Build, override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (lookupEnvBuild(b, "ANDROID_HOME")) |p| return p;
    return lookupEnvBuild(b, "ANDROID_SDK_ROOT");
}

fn lookupEnvBuild(b: *std.Build, name: []const u8) ?[]const u8 {
    if (b.graph.environ_map.get(name)) |value| {
        if (value.len != 0) return value;
    }

    // Defensive fallback: walk the map directly in case hash lookup misses.
    // This keeps env resolution resilient across toolchain/runtime quirks.
    var it = b.graph.environ_map.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, name)) continue;
        if (entry.value_ptr.*.len == 0) return null;
        return entry.value_ptr.*;
    }
    return null;
}

fn bionicLibCFile(b: *std.Build, sysroot: []const u8, api_level: u32) std.Build.LazyPath {
    const crt_dir = detectCrtDir(b, sysroot, api_level);
    const wf = b.addWriteFiles();
    const contents = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/aarch64-linux-android
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir={s}
        \\gcc_dir={s}
        \\darwin_sdk_dir=
        \\
    , .{ sysroot, sysroot, crt_dir, crt_dir, crt_dir });
    return wf.add("android-bionic-libc.txt", contents);
}

fn hostPrebuiltCandidates() []const []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => &.{ "darwin-arm64", "darwin-x86_64" },
            .x86_64 => &.{ "darwin-x86_64", "darwin-arm64" },
            else => @panic("unsupported macOS CPU arch for Android NDK cross-compile"),
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => &.{ "linux-aarch64", "linux-x86_64" },
            .x86_64 => &.{ "linux-x86_64", "linux-aarch64" },
            else => @panic("unsupported Linux CPU arch for Android NDK cross-compile"),
        },
        .windows => switch (builtin.cpu.arch) {
            .aarch64 => &.{ "windows-arm64", "windows-x86_64" },
            .x86_64 => &.{ "windows-x86_64", "windows-arm64" },
            else => @panic("unsupported Windows CPU arch for Android NDK cross-compile"),
        },
        else => @panic("unsupported host OS for Android NDK cross-compile"),
    };
}

fn detectCrtDir(b: *std.Build, sysroot: []const u8, api_level: u32) []const u8 {
    const io = b.graph.io;
    const api_dir = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android", b.fmt("{d}", .{api_level}) });
    if (std.Io.Dir.cwd().access(io, api_dir, .{})) |_| return api_dir else |_| {}

    const abi_dir = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android" });
    if (std.Io.Dir.cwd().access(io, abi_dir, .{})) |_| return abi_dir else |_| {}

    const lib64_dir = b.pathJoin(&.{ sysroot, "usr", "lib64" });
    if (std.Io.Dir.cwd().access(io, lib64_dir, .{})) |_| return lib64_dir else |_| {}

    const lib_dir = b.pathJoin(&.{ sysroot, "usr", "lib" });
    if (std.Io.Dir.cwd().access(io, lib_dir, .{})) |_| return lib_dir else |_| {}

    @panic("could not find Android NDK crt dir; checked common NDK layouts");
}

fn resolveHostPrebuiltTag(b: *std.Build, ndk_root: []const u8) []const u8 {
    const io = b.graph.io;
    for (hostPrebuiltCandidates()) |tag| {
        const path = b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt", tag });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return tag;
    }
    @panic("could not find Android NDK host prebuilt dir for this host");
}
