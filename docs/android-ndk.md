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

## Emulator tests (`zig build android-test`)

UiAutomator tests that drive the real app (menus, dialogs, play pad, system pickers) and check what the file bridge did: MediaStore rows under `Download/Sudoku/`, the `sudoku_file_binding` prefs, the saved file. Not part of `zig build verify`; it needs a running emulator.

**Prerequisites** (SDK Manager; Android Studio itself is not needed): build-tools, platform-tools (`adb`), an Android platform, the Android Emulator and an arm64 system image, plus the NDK and `JAVA_HOME` as above.

Start an emulator, then run:

```bash
emulator -list-avds
emulator -avd <name> &
adb devices            # exactly one device, state "device"
zig build android-test
```

The step builds the app APK and a separate, self-instrumenting test APK (`com.wigzell.sudoku_zig.test`, `src/android/test/`), installs both, runs `am instrument` with `AndroidJUnitRunner`, and fails on any failed test, printing the full instrumentation output. A failed test leaves a screenshot and window hierarchy in `zig-out/android-test/failure/`. The earlier-install scenarios uninstall and reinstall the app during the run (from a copy pushed to `/data/local/tmp`); a full run takes about two minutes.

**Device state is put back afterwards:** the app's private data is backed up (`run-as … tar`) and restored; the user's `Download/Sudoku/sudoku.sud` and any `sudoku (N).sud` are moved to `Download/sudoku-test-hold/` for the run and moved back (a move keeps their MediaStore rows and owners); other files in the folder are not touched. A copy of the folder is also kept in `zig-out/android-test/backup/`.

**Libraries:** the androidx test jars are committed in `third_party/androidx-test/` with their licences, pinned by version and SHA-256 in `scripts/android-test.sh`. A missing file is downloaded from Google Maven / Maven Central on the next run; a hash mismatch fails the step. The pins are the newest releases that need no Kotlin runtime (monitor 1.6.1 and later do).
