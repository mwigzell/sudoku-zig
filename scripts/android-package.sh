#!/usr/bin/env bash
# Build + package + debug-sign Sudoku Android APK from prepared JNI lib output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 9 ]]; then
  echo "usage: $0 <sdk_root> <min_api> <out_dir> <main_java> <jni_java> <manifest> <res_dir> <so_path> <apk_name>" >&2
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

pick_latest_dir() {
  ls -1 "$1" 2>/dev/null | sort -V | awk 'NF {v=$0} END {print v}'
}

PLATFORM_DIR="$(pick_latest_dir "$SDK_ROOT/platforms")"
case "$PLATFORM_DIR" in
  android-*)
    PLATFORM_API="${PLATFORM_DIR#android-}"
    ;;
  *)
    echo "error: no Android platform found under $SDK_ROOT/platforms (expected android-<api>)" >&2
    exit 1
    ;;
esac

PLATFORM_API_INT="${PLATFORM_API%%.*}"
if [[ "$PLATFORM_API_INT" -lt "$MIN_API" ]]; then
  echo "error: newest Android platform api ($PLATFORM_API) is below required $MIN_API" >&2
  exit 1
fi

ANDROID_JAR="$SDK_ROOT/platforms/$PLATFORM_DIR/android.jar"
if [[ ! -f "$ANDROID_JAR" ]]; then
  echo "error: missing Android platform jar: $ANDROID_JAR" >&2
  exit 1
fi

BUILD_TOOLS_VERSION="$(pick_latest_dir "$SDK_ROOT/build-tools")"
if [[ -z "$BUILD_TOOLS_VERSION" ]]; then
  echo "error: no Android build-tools found under $SDK_ROOT/build-tools" >&2
  exit 1
fi

BUILD_TOOLS="$SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION"
AAPT="$BUILD_TOOLS/aapt"
D8="$BUILD_TOOLS/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
for tool in "$AAPT" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
  if [[ ! -x "$tool" ]]; then
    echo "error: missing executable: $tool" >&2
    exit 1
  fi
done

if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
  JAVAC="$JAVA_HOME/bin/javac"
else
  JAVAC="$(command -v javac || true)"
fi
if [[ -z "${JAVAC:-}" || ! -x "$JAVAC" ]]; then
  echo "error: javac not found. Set JAVA_HOME to a JDK 17+ install." >&2
  exit 1
fi

if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/keytool" ]]; then
  KEYTOOL="$JAVA_HOME/bin/keytool"
else
  KEYTOOL="$(command -v keytool || true)"
fi
if [[ -z "${KEYTOOL:-}" || ! -x "$KEYTOOL" ]]; then
  echo "error: keytool not found. Set JAVA_HOME to a JDK install." >&2
  exit 1
fi

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
"$AAPT" package -f -M "$MANIFEST_PATH" -S "$RESOURCE_PATH" -I "$ANDROID_JAR" -F "$OUT/unsigned.apk"
cp "$OUT/classes.dex" "$APK_ROOT/classes.dex"
cp "$SO_PATH" "$APK_ROOT/lib/arm64-v8a/libsudoku_zig.so"
cp "$OUT/unsigned.apk" "$OUT/unaligned.apk"
(cd "$APK_ROOT" && zip -qr "$OUT/unaligned.apk" classes.dex lib)
"$ZIPALIGN" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"

DEBUG_KEYSTORE="${ANDROID_DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
if [[ ! -f "$DEBUG_KEYSTORE" ]]; then
  mkdir -p "$(dirname "$DEBUG_KEYSTORE")"
  "$KEYTOOL" -genkeypair -v \
    -keystore "$DEBUG_KEYSTORE" \
    -storepass android \
    -alias androiddebugkey \
    -keypass android \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi

"$APKSIGNER" sign \
  --ks "$DEBUG_KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$OUT/$APK_NAME" \
  "$OUT/aligned.apk"

echo "APK ready: $OUT/$APK_NAME"
