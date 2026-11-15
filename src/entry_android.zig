//! Android entry export surface — delegates JNI callbacks to `android/jni_host.zig`.
const jni_host = @import("android/jni_host.zig");

export fn Java_com_wigzell_sudoku_1zig_JniHost_startHostNative(
    env: *anyopaque,
    class: *anyopaque,
    data_dir_jstring: *anyopaque,
) callconv(.c) void {
    jni_host.startHost(env, data_dir_jstring);
    _ = class;
}

/// Where the boot stands, as one value: `0` starting, `-1` refused, otherwise the serving port.
export fn Java_com_wigzell_sudoku_1zig_JniHost_bootState(
    _: *anyopaque,
    _: *anyopaque,
) callconv(.c) i32 {
    return jni_host.bootState();
}

export fn Java_com_wigzell_sudoku_1zig_JniHost_stopHost(
    _: *anyopaque,
    _: *anyopaque,
) callconv(.c) void {
    jni_host.stopHost();
}

export fn Java_com_wigzell_sudoku_1zig_JniHost_logIdentityNative(
    env: *anyopaque,
    _: *anyopaque,
) callconv(.c) ?*anyopaque {
    return jni_host.logIdentity(env);
}

export fn Java_com_wigzell_sudoku_1zig_JniHost_defaultFolderNameNative(
    env: *anyopaque,
    _: *anyopaque,
) callconv(.c) ?*anyopaque {
    return jni_host.defaultFolderName(env);
}

/// Entry export for `jni_host.startupFailureMessage`: core's sentence for a refused boot.
export fn Java_com_wigzell_sudoku_1zig_JniHost_startupFailureMessageNative(
    env: *anyopaque,
    _: *anyopaque,
) callconv(.c) ?*anyopaque {
    return jni_host.startupFailureMessage(env);
}
