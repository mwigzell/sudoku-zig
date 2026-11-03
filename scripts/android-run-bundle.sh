#!/usr/bin/env bash
# Unpack the App Bundle into one universal sudoku.apk, install it on the one connected device or emulator and launch it.
# Usage: scripts/android-run-bundle.sh [aab]   (default zig-out/android-bundle/sudoku.aab; build it with zig build android-bundle)
# bundletool signs the APK with the debug keystore, the same key as zig build android, so it installs over the debug build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

AAB="${1:-zig-out/android-bundle/sudoku.aab}"
OUT="zig-out/android-bundle/apk"
APP_PACKAGE="com.wigzell.sudoku_zig"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"

if [[ -z "$SDK_ROOT" ]]; then
  echo "error: Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT." >&2
  exit 1
fi
ADB="$SDK_ROOT/platform-tools/adb"
if [[ ! -x "$ADB" ]]; then
  echo "error: missing executable: $ADB (install Android SDK platform-tools)" >&2
  exit 1
fi
if [[ ! -f "$AAB" ]]; then
  echo "error: App Bundle not found: $AAB (run zig build android-bundle)" >&2
  exit 1
fi

source "$ROOT/scripts/android-sdk-tools.sh"
JAVA="$(jdk_tool java)"
resolve_bundletool "$ROOT"

DEVICES="$("$ADB" devices | awk 'NR > 1 && $2 == "device" {print $1}')"
if [[ "$(echo "$DEVICES" | grep -c .)" -ne 1 ]]; then
  echo "error: expected exactly one connected device or emulator (adb devices)" >&2
  exit 1
fi
export ANDROID_SERIAL="$DEVICES"

rm -rf "$OUT"
mkdir -p "$OUT"
"$JAVA" -jar "$BUNDLETOOL_JAR" build-apks --bundle="$AAB" --output="$OUT/sudoku.apks" --mode=universal >/dev/null
unzip -qo "$OUT/sudoku.apks" universal.apk -d "$OUT"
mv "$OUT/universal.apk" "$OUT/sudoku.apk"

"$ADB" install -r "$OUT/sudoku.apk" >/dev/null
"$ADB" shell monkey -p "$APP_PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo "Installed $OUT/sudoku.apk on $DEVICES and launched it"
