# Android NDK setup (host)

Sudoku Zig’s Android path cross-compiles **`libsudoku_zig.so`** with **`zig build android`** (no Gradle). You need a standard SDK install plus one **NDK (Side by side)**.

## Install (Android Studio)

1. **Settings → Languages & Frameworks → Android SDK → SDK Tools**
2. Enable **NDK (Side by side)** and **Android SDK Command-line Tools (latest)**.
3. Apply — one NDK version under `~/Library/Android/sdk/ndk/<version>` is enough.

CMake is **not** required; native code is built by Zig.

## Environment

| Variable | Purpose |
|----------|---------|
| `ANDROID_HOME` or `ANDROID_SDK_ROOT` | SDK root (e.g. `~/Library/Android/sdk`) |
| `ANDROID_NDK_HOME` | NDK root (e.g. `$ANDROID_HOME/ndk/30.0.16248370`) |
| `JAVA_HOME` | JDK 17+ for later APK sign/dex steps |

Optional: add `$ANDROID_HOME/platform-tools` and `$ANDROID_HOME/cmdline-tools/latest/bin` to `PATH` for `adb` / `sdkmanager`.

Override NDK path for one build:

```bash
zig build android -Dndk=/path/to/ndk
```

## Build artifact (Step 3)

Default target: **`aarch64-linux-android`** API **29** (arm64-v8a). Output:

```text
zig-out/lib/libsudoku_zig.so
```

Installable APK, WebView, and JNI wiring are later steps in the Android slice.

## Verify on host

With NDK configured:

```bash
zig build android
file zig-out/lib/libsudoku_zig.so
```

Expect `ELF 64-bit LSB shared object, ARM aarch64`.
