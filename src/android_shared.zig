//! Shared-library root at `src/` — exports JNI symbols and delegates to `android/jni_host.zig`.
const jni_host = @import("android/jni_host.zig");

export fn Java_com_wigzell_sudoku_1zig_JniHost_startHostNative(
    env: *anyopaque,
    class: *anyopaque,
    data_dir_jstring: *anyopaque,
) callconv(.c) void {
    jni_host.startHost(env, data_dir_jstring);
    _ = class;
}

export fn Java_com_wigzell_sudoku_1zig_JniHost_readyPort(
    _: *anyopaque,
    _: *anyopaque,
) callconv(.c) i32 {
    return jni_host.readyPort();
}

export fn Java_com_wigzell_sudoku_1zig_JniHost_stopHost(
    _: *anyopaque,
    _: *anyopaque,
) callconv(.c) void {
    jni_host.stopHost();
}
