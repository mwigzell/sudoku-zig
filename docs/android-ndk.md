# Android NDK setup (host)

Sudoku Zig’s Android path builds an APK with **`zig build android`** (no Gradle). You need a standard SDK install plus one **NDK (Side by side)**.

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
| `JAVA_HOME` | JDK 17+ (required for `javac` + debug keystore tooling) |

Optional: add `$ANDROID_HOME/platform-tools` and `$ANDROID_HOME/cmdline-tools/latest/bin` to `PATH` for `adb` / `sdkmanager`.

Override roots for one build:

```bash
zig build android -Dndk=/path/to/ndk
zig build android -Dsdk=/path/to/sdk
```

## Build artifacts (Step 3 + Step 4)

Default native API: **`aarch64-linux-android`** API **29** (arm64-v8a); APK manifest targets Android API **33**.

Library-only build (Step 3):

```text
zig-out/lib/libsudoku_zig.so
```

Full APK build (Step 4):

```text
zig-out/android/sudoku.apk
```

Use `zig build android-lib` when you only want the `.so`.

## Runtime wiring (Step 5)

- `MainActivity.onCreate` starts the JNI host on a background thread.
- Bootstrap waits for native `readyPort()` and then loads `http://127.0.0.1:<port>/` in WebView on the UI thread.
- `MainActivity.onDestroy` calls `stopHost()` to shut down the loopback server cleanly.

## Verify on host

With SDK + NDK configured:

```bash
zig build android-lib
file zig-out/lib/libsudoku_zig.so
zig build android
ls zig-out/android/sudoku.apk
```

Expect `ELF 64-bit LSB shared object, ARM aarch64`.
