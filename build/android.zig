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
const JniHelpersC = "src/android/jni_helpers.c";

pub fn addAndroidStep(b: *std.Build, deps: struct {
    wasm_emit: *std.Build.Step,
    gen_build_info: *std.Build.Step,
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
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const host_prebuilt = resolveHostPrebuiltTag(b, ndk_root);
    const sysroot = b.pathJoin(&.{
        ndk_root,
        "toolchains",
        "llvm",
        "prebuilt",
        host_prebuilt,
        "sysroot",
    });
    const merged_crt_dir = b.pathJoin(&.{
        buildCwd(b),
        OutDir,
        "crt",
        "aarch64-linux-android",
        b.fmt("{d}", .{android_api_level}),
    });
    const prepare_crt = addPrepareMergedCrtStep(b, sysroot, android_api_level, merged_crt_dir);

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
    shared.root_module.addCSourceFile(.{
        .file = b.path(JniHelpersC),
    });
    shared.setLibCFile(bionicLibCFile(b, sysroot, merged_crt_dir));
    shared.root_module.pic = true;
    shared.step.dependOn(deps.wasm_emit);
    shared.step.dependOn(deps.gen_build_info);
    shared.step.dependOn(&prepare_crt.step);

    const install = b.addInstallArtifact(shared, .{});
    const android_lib_step = b.step("android-lib", "Cross-compile libsudoku_zig.so for aarch64-linux-android (arm64-v8a)");
    android_lib_step.dependOn(&install.step);

    const sdk_opt = b.option([]const u8, "sdk", "Android SDK root (default: $ANDROID_HOME or $ANDROID_SDK_ROOT)");
    const sdk_root = resolveSdkRoot(b, sdk_opt) orelse {
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
    const value = b.graph.environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn buildCwd(b: *std.Build) []const u8 {
    return lookupEnvBuild(b, "PWD") orelse ".";
}

fn bionicLibCFile(b: *std.Build, sysroot: []const u8, crt_dir: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    const contents = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/aarch64-linux-android
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, crt_dir });
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

fn resolveHostPrebuiltTag(b: *std.Build, ndk_root: []const u8) []const u8 {
    const io = b.graph.io;
    for (hostPrebuiltCandidates()) |tag| {
        const path = b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt", tag });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return tag;
    }
    @panic("could not find Android NDK host prebuilt dir for this host");
}

fn addPrepareMergedCrtStep(b: *std.Build, sysroot: []const u8, api_level: u32, out_dir: []const u8) *std.Build.Step.Run {
    const prep = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\sysroot="$1"
        \\api="$2"
        \\out="$3"
        \\abi_dir="$sysroot/usr/lib/aarch64-linux-android"
        \\api_dir="$abi_dir/$api"
        \\
        \\rm -rf "$out"
        \\mkdir -p "$out"
        \\
        \\copy_files() {
        \\  d="$1"
        \\  [ -d "$d" ] || return 0
        \\  for f in "$d"/*; do
        \\    [ -f "$f" ] || continue
        \\    [ -e "$f" ] || continue
        \\    cp -f "$f" "$out/"
        \\  done
        \\}
        \\
        \\copy_files "$abi_dir"
        \\copy_files "$api_dir"
        \\
        \\set -- "$out"/*.o
        \\if [ ! -e "$1" ]; then
        \\  echo "error: no crt objects found in $abi_dir or $api_dir" >&2
        \\  exit 1
        \\fi
        ,
        "--",
        sysroot,
        b.fmt("{d}", .{api_level}),
        out_dir,
    });
    return prep;
}
