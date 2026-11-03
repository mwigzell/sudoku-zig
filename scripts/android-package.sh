#!/usr/bin/env bash
# Build, package and debug-sign the Sudoku Android APK from the prepared JNI library (development builds; releases are bundles).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 11 ]]; then
  echo "usage: $0 <sdk_root> <min_api> <out_dir> <main_java> <jni_java> <manifest> <res_dir> <so_path> <apk_name> <version_code> <version_name>" >&2
  exit 1
fi

SDK_ROOT="$1"
MIN_API="$2"
OUT_REL="$3"
MAIN_JAVA="$4"
JNI_JAVA="$5"
MANIFEST_PATH="$6"
RESOURCE_PATH="$7"
SO_PATH="$8"
APK_NAME="$9"
VERSION_CODE="${10}"
VERSION_NAME="${11}"

source "$ROOT/scripts/android-sdk-tools.sh"
resolve_android_tools "$SDK_ROOT" "$MIN_API"

OUT="$ROOT/$OUT_REL"
APK_ROOT="$OUT/apk-root"
CLASSES="$OUT/classes"
rm -rf "$OUT"
mkdir -p "$APK_ROOT/lib/arm64-v8a" "$CLASSES"

"$JAVAC" --release 17 -cp "$ANDROID_JAR" -d "$CLASSES" "$MAIN_JAVA" "$JNI_JAVA"

CLASS_FILES=()
while IFS= read -r class_file; do
  CLASS_FILES+=("$class_file")
done < <(find "$CLASSES" -name '*.class' -print)
if [[ "${#CLASS_FILES[@]}" -eq 0 ]]; then
  echo "error: javac produced no .class files under $CLASSES" >&2
  exit 1
fi

"$D8" --min-api "$MIN_API" --output "$OUT" "${CLASS_FILES[@]}"
# Debug APKs must be manifest-debuggable for adb run-as and app-private inspection.
"$AAPT" package -f --debug-mode --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version -M "$MANIFEST_PATH" -S "$RESOURCE_PATH" -I "$ANDROID_JAR" -F "$OUT/unsigned.apk"
cp "$OUT/classes.dex" "$APK_ROOT/classes.dex"
cp "$SO_PATH" "$APK_ROOT/lib/arm64-v8a/libsudoku_zig.so"
cp "$OUT/unsigned.apk" "$OUT/unaligned.apk"
(cd "$APK_ROOT" && zip -qr "$OUT/unaligned.apk" classes.dex lib)
"$ZIPALIGN" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"

sign_debug_apk "$OUT/aligned.apk" "$OUT/$APK_NAME"

echo "APK ready: $OUT/$APK_NAME"
