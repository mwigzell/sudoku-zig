#!/usr/bin/env bash
# Build + package + debug-sign Sudoku Android APK from prepared JNI lib output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 12 ]]; then
  echo "usage: $0 <sdk_root> <min_api> <out_dir> <main_java> <jni_java> <manifest> <res_dir> <so_path> <apk_name> <version_code> <version_name> <signing_mode>" >&2
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
SIGNING_MODE="${12}"

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
if [[ "$SIGNING_MODE" == "debug" ]]; then
  # Debug APKs must be manifest-debuggable for adb run-as and app-private inspection.
  "$AAPT" package -f --debug-mode --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version -M "$MANIFEST_PATH" -S "$RESOURCE_PATH" -I "$ANDROID_JAR" -F "$OUT/unsigned.apk"
else
  "$AAPT" package -f --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version -M "$MANIFEST_PATH" -S "$RESOURCE_PATH" -I "$ANDROID_JAR" -F "$OUT/unsigned.apk"
fi
cp "$OUT/classes.dex" "$APK_ROOT/classes.dex"
cp "$SO_PATH" "$APK_ROOT/lib/arm64-v8a/libsudoku_zig.so"
cp "$OUT/unsigned.apk" "$OUT/unaligned.apk"
(cd "$APK_ROOT" && zip -qr "$OUT/unaligned.apk" classes.dex lib)
"$ZIPALIGN" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"

if [[ "$SIGNING_MODE" == "debug" ]]; then
  sign_debug_apk "$OUT/aligned.apk" "$OUT/$APK_NAME"
elif [[ "$SIGNING_MODE" == "release" ]]; then
  RELEASE_KEYSTORE="${ANDROID_RELEASE_KEYSTORE:-}"
  RELEASE_STORE_PASS="${ANDROID_RELEASE_STORE_PASS:-}"
  RELEASE_KEY_ALIAS="${ANDROID_RELEASE_KEY_ALIAS:-}"
  RELEASE_KEY_PASS="${ANDROID_RELEASE_KEY_PASS:-$RELEASE_STORE_PASS}"
  if [[ -z "$RELEASE_KEYSTORE" ]]; then
    echo "error: ANDROID_RELEASE_KEYSTORE is required for release signing" >&2
    exit 1
  fi
  if [[ -z "$RELEASE_STORE_PASS" ]]; then
    echo "error: ANDROID_RELEASE_STORE_PASS is required for release signing" >&2
    exit 1
  fi
  if [[ -z "$RELEASE_KEY_ALIAS" ]]; then
    echo "error: ANDROID_RELEASE_KEY_ALIAS is required for release signing" >&2
    exit 1
  fi
  if [[ -z "$RELEASE_KEY_PASS" ]]; then
    echo "error: ANDROID_RELEASE_KEY_PASS is required for release signing" >&2
    exit 1
  fi
  if [[ ! -f "$RELEASE_KEYSTORE" ]]; then
    echo "error: release keystore does not exist: $RELEASE_KEYSTORE" >&2
    exit 1
  fi

  # Preflight keystore access using keytool so failures are clearer than apksigner stack traces.
  if ! "$KEYTOOL" -list -keystore "$RELEASE_KEYSTORE" -storepass "$RELEASE_STORE_PASS" >/dev/null 2>&1; then
    echo "error: release keystore/password check failed (ANDROID_RELEASE_KEYSTORE / ANDROID_RELEASE_STORE_PASS)" >&2
    exit 1
  fi

  # apksigner env: mode avoids parser edge-cases in pass: mode for special characters.
  export ANDROID_RELEASE_STORE_PASS="$RELEASE_STORE_PASS"
  export ANDROID_RELEASE_KEY_PASS="$RELEASE_KEY_PASS"

  "$APKSIGNER" sign \
    --ks "$RELEASE_KEYSTORE" \
    --ks-pass "env:ANDROID_RELEASE_STORE_PASS" \
    --key-pass "env:ANDROID_RELEASE_KEY_PASS" \
    --ks-key-alias "$RELEASE_KEY_ALIAS" \
    --out "$OUT/$APK_NAME" \
    "$OUT/aligned.apk"
else
  echo "error: signing_mode must be 'debug' or 'release' (got '$SIGNING_MODE')" >&2
  exit 1
fi

echo "APK ready: $OUT/$APK_NAME"
