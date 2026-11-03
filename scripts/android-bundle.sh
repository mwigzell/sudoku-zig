#!/usr/bin/env bash
# Build, package and release-sign the Sudoku Android App Bundle (.aab) for Google Play from the prepared JNI library.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 11 ]]; then
  echo "usage: $0 <sdk_root> <min_api> <out_dir> <main_java> <jni_java> <manifest> <res_dir> <so_path> <aab_name> <version_code> <version_name>" >&2
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
AAB_NAME="$9"
VERSION_CODE="${10}"
VERSION_NAME="${11}"

source "$ROOT/scripts/android-sdk-tools.sh"
resolve_android_tools "$SDK_ROOT" "$MIN_API"
require_release_signing
resolve_bundletool "$ROOT"

OUT="$ROOT/$OUT_REL"
CLASSES="$OUT/classes"
MODULE="$OUT/base"
rm -rf "$OUT"
mkdir -p "$CLASSES" "$MODULE/manifest" "$MODULE/dex" "$MODULE/lib/arm64-v8a"

"$JAVAC" --release 17 -cp "$ANDROID_JAR" -d "$CLASSES" "$MAIN_JAVA" "$JNI_JAVA"
CLASS_FILES=()
while IFS= read -r class_file; do
  CLASS_FILES+=("$class_file")
done < <(find "$CLASSES" -name '*.class' -print)
if [[ "${#CLASS_FILES[@]}" -eq 0 ]]; then
  echo "error: javac produced no .class files under $CLASSES" >&2
  exit 1
fi
"$D8" --release --min-api "$MIN_API" --output "$MODULE/dex" "${CLASS_FILES[@]}"

# A bundle module carries resources and the manifest in aapt2's proto format.
"$AAPT2" compile --dir "$RESOURCE_PATH" -o "$OUT/resources.zip"
"$AAPT2" link --proto-format -o "$OUT/linked.zip" -I "$ANDROID_JAR" --manifest "$MANIFEST_PATH" \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --replace-version "$OUT/resources.zip"
unzip -q "$OUT/linked.zip" -d "$MODULE"
mv "$MODULE/AndroidManifest.xml" "$MODULE/manifest/AndroidManifest.xml"
cp "$SO_PATH" "$MODULE/lib/arm64-v8a/libsudoku_zig.so"
(cd "$MODULE" && zip -qr "$OUT/base.zip" .)

"$JAVA" -jar "$BUNDLETOOL_JAR" build-bundle --modules="$OUT/base.zip" --output="$OUT/unsigned.aab"
"$JARSIGNER" -sigalg SHA256withRSA -digestalg SHA-256 \
  -keystore "$ANDROID_RELEASE_KEYSTORE" -storepass:env ANDROID_RELEASE_STORE_PASS -keypass:env ANDROID_RELEASE_KEY_PASS \
  -signedjar "$OUT/$AAB_NAME" "$OUT/unsigned.aab" "$ANDROID_RELEASE_KEY_ALIAS" >/dev/null
"$JAVA" -jar "$BUNDLETOOL_JAR" validate --bundle="$OUT/$AAB_NAME" >/dev/null

echo "App Bundle ready: $OUT/$AAB_NAME"
