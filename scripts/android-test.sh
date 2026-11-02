#!/usr/bin/env bash
# Build the UiAutomator test APK, run it against the installed app on a connected device, restore the device after.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -ne 6 ]]; then
  echo "usage: $0 <sdk_root> <min_api> <app_apk> <out_dir> <test_manifest> <test_java>" >&2
  exit 1
fi

SDK_ROOT="$1"
MIN_API="$2"
APP_APK="$ROOT/$3"
OUT="$ROOT/$4"
TEST_MANIFEST="$5"
TEST_JAVA="$6"

APP_PACKAGE="com.wigzell.sudoku_zig"
TEST_PACKAGE="com.wigzell.sudoku_zig.test"
RUNNER="androidx.test.runner.AndroidJUnitRunner"
SAVE_DIR="/sdcard/Download/Sudoku"
LIBS="$ROOT/third_party/androidx-test"
GOOGLE_MAVEN="https://dl.google.com/dl/android/maven2"
MAVEN_CENTRAL="https://repo1.maven.org/maven2"

# Pinned test libraries: file, source URL, sha256. Committed under third_party; fetched only when missing.
# Versions are the newest whose classes need no Kotlin runtime (monitor 1.6.1+ does).
PINNED_LIBS=(
  "uiautomator-2.3.0.aar|$GOOGLE_MAVEN/androidx/test/uiautomator/uiautomator/2.3.0/uiautomator-2.3.0.aar|884c675c336b663f53a1d0de440642ee80d2bdf9d0049abdae2a3ecd5e6320fc"
  "runner-1.5.0.aar|$GOOGLE_MAVEN/androidx/test/runner/1.5.0/runner-1.5.0.aar|b3c5aabd545b6c260528c8f4e7c98f73628614ea3d5df3a7a44af2136fd8720b"
  "monitor-1.6.0.aar|$GOOGLE_MAVEN/androidx/test/monitor/1.6.0/monitor-1.6.0.aar|05ed2e6ee93271d1d8ffe3f06739e5b621cbe37880b24adf4ce2f49ebd59fda3"
  "storage-1.4.2.aar|$GOOGLE_MAVEN/androidx/test/services/storage/1.4.2/storage-1.4.2.aar|b34861f0cd920cb1089f08c3f27e5865b7f920284cc45f4ed12ef8d6980dac48"
  "annotation-1.0.1.aar|$GOOGLE_MAVEN/androidx/test/annotation/1.0.1/annotation-1.0.1.aar|c0754928effe1968c3a9a7b55d1dfc7ceb1e1e7c9f3f09f98afd42431f712492"
  "tracing-1.1.0.aar|$GOOGLE_MAVEN/androidx/tracing/tracing/1.1.0/tracing-1.1.0.aar|5b78e2c618fc10b3d14decc01df76158f15954ad746aacf0607766721da081f6"
  "annotation-1.2.0.jar|$GOOGLE_MAVEN/androidx/annotation/annotation/1.2.0/annotation-1.2.0.jar|9029262bddce116e6d02be499e4afdba21f24c239087b76b3b57d7e98b490a36"
  "junit-4.13.2.jar|$MAVEN_CENTRAL/junit/junit/4.13.2/junit-4.13.2.jar|8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3"
  "hamcrest-core-1.3.jar|$MAVEN_CENTRAL/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar|66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9"
)

source "$ROOT/scripts/android-sdk-tools.sh"
resolve_android_tools "$SDK_ROOT" "$MIN_API"

ADB="$SDK_ROOT/platform-tools/adb"
if [[ ! -x "$ADB" ]]; then
  echo "error: missing executable: $ADB (install Android SDK platform-tools)" >&2
  exit 1
fi
if [[ ! -f "$APP_APK" ]]; then
  echo "error: app APK not found: $APP_APK" >&2
  exit 1
fi

# ── libraries: verify pinned files, fetch missing ones, unpack AARs to classes jars ──
rm -rf "$OUT"
mkdir -p "$OUT/jars" "$OUT/classes" "$OUT/backup"
mkdir -p "$LIBS"
CLASSPATH_JARS=()
for entry in "${PINNED_LIBS[@]}"; do
  IFS='|' read -r file url sha <<<"$entry"
  if [[ ! -f "$LIBS/$file" ]]; then
    echo "fetching $file"
    curl -fsSL -o "$LIBS/$file.part" "$url"
    mv "$LIBS/$file.part" "$LIBS/$file"
  fi
  actual="$(shasum -a 256 "$LIBS/$file" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "error: $file sha256 is $actual, expected $sha" >&2
    exit 1
  fi
  case "$file" in
    *.aar)
      unzip -qo -d "$OUT/jars/${file%.aar}" "$LIBS/$file" classes.jar
      CLASSPATH_JARS+=("$OUT/jars/${file%.aar}/classes.jar")
      ;;
    *.jar)
      CLASSPATH_JARS+=("$LIBS/$file")
      ;;
  esac
done
CLASSPATH="$(IFS=:; echo "${CLASSPATH_JARS[*]}")"

# ── test APK ──
"$JAVAC" --release 17 -cp "$ANDROID_JAR:$CLASSPATH" -d "$OUT/classes" "$TEST_JAVA"
CLASS_FILES=()
while IFS= read -r class_file; do
  CLASS_FILES+=("$class_file")
done < <(find "$OUT/classes" -name '*.class' -print)
"$D8" --min-api "$MIN_API" --lib "$ANDROID_JAR" --output "$OUT" "${CLASS_FILES[@]}" "${CLASSPATH_JARS[@]}"
"$AAPT" package -f -M "$TEST_MANIFEST" -I "$ANDROID_JAR" -F "$OUT/unaligned.apk"
(cd "$OUT" && zip -q unaligned.apk classes.dex)
"$ZIPALIGN" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"
sign_debug_apk "$OUT/aligned.apk" "$OUT/sudoku-test.apk"

# ── device: one connected device; back up the app's data, set the user's default save file aside, restore on exit ──
DEVICES="$("$ADB" devices | awk 'NR > 1 && $2 == "device" {print $1}')"
if [[ "$(echo "$DEVICES" | grep -c .)" -ne 1 ]]; then
  echo "error: expected exactly one connected device or emulator (adb devices); start the emulator first" >&2
  exit 1
fi

APP_INSTALLED=0
if "$ADB" shell pm path "$APP_PACKAGE" >/dev/null 2>&1; then
  APP_INSTALLED=1
fi
"$ADB" install -r "$APP_APK" >/dev/null
"$ADB" shell am force-stop "$APP_PACKAGE"
if [[ "$APP_INSTALLED" -eq 1 ]]; then
  "$ADB" exec-out run-as "$APP_PACKAGE" tar cf - . > "$OUT/backup/appdata.tar"
fi
# The user's default save file (and renamed copies) move aside, not delete-and-push: a move keeps their MediaStore rows.
HOLD_DIR="/sdcard/Download/sudoku-test-hold"
DEFAULT_FILES_GLOB="'$SAVE_DIR/sudoku.sud' '$SAVE_DIR'/sudoku\\ \\(*\\).sud"
# The reinstall scenario installs the app from this copy; failed tests leave a screenshot and window hierarchy here.
APP_APK_ON_DEVICE="/data/local/tmp/sudoku-app.apk"
FAILURE_DIR="/data/local/tmp/sudoku-test-failure"
HAD_SAVE_DIR=0
if "$ADB" shell ls "$SAVE_DIR" >/dev/null 2>&1; then
  HAD_SAVE_DIR=1
  "$ADB" pull "$SAVE_DIR" "$OUT/backup/" >/dev/null
fi
# Folders removed from the shell keep their MediaStore rows; drop them so pickers do not list a missing folder.
forget_folder() {
  "$ADB" shell "rmdir '$1' 2>/dev/null && content delete --uri content://media/external/file --where \"_data='${1/#\/sdcard/\/storage\/emulated\/0}'\"; true"
}
restore_device() {
  "$ADB" shell am force-stop "$APP_PACKAGE" || true
  "$ADB" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
  "$ADB" shell rm -f "$APP_APK_ON_DEVICE" || true
  if ! "$ADB" shell pm path "$APP_PACKAGE" >/dev/null 2>&1; then
    "$ADB" install -r "$APP_APK" >/dev/null || echo "warning: app not reinstalled" >&2
  fi
  "$ADB" shell pm clear "$APP_PACKAGE" >/dev/null || true
  if [[ -s "$OUT/backup/appdata.tar" ]]; then
    "$ADB" exec-in run-as "$APP_PACKAGE" tar xf - < "$OUT/backup/appdata.tar" || echo "warning: app data restore failed; backup kept at $OUT/backup/appdata.tar" >&2
  fi
  "$ADB" shell "rm -f $DEFAULT_FILES_GLOB; for f in '$HOLD_DIR'/*; do [ -e \"\$f\" ] && mv \"\$f\" '$SAVE_DIR/'; done; true" \
    || echo "warning: save files not moved back; they are in $HOLD_DIR (copy in $OUT/backup)" >&2
  forget_folder "$HOLD_DIR"
  if [[ "$HAD_SAVE_DIR" -eq 0 ]]; then
    forget_folder "$SAVE_DIR"
  fi
  "$ADB" shell rm -rf "$FAILURE_DIR" || true
}
trap restore_device EXIT
"$ADB" shell "mkdir -p '$HOLD_DIR' && for f in $DEFAULT_FILES_GLOB; do [ -e \"\$f\" ] && mv \"\$f\" '$HOLD_DIR/'; done; true"

# ── run ──
"$ADB" push "$APP_APK" "$APP_APK_ON_DEVICE" >/dev/null
"$ADB" shell rm -rf "$FAILURE_DIR"
"$ADB" install -r -t "$OUT/sudoku-test.apk" >/dev/null
RESULT="$("$ADB" shell am instrument -w -r "$TEST_PACKAGE/$RUNNER" | tr -d '\r')"
if ! echo "$RESULT" | grep -q '^OK ('; then
  echo "$RESULT"
  if "$ADB" pull "$FAILURE_DIR" "$OUT/failure" >/dev/null 2>&1; then
    echo "failure screenshots and window hierarchies: $OUT/failure" >&2
  fi
  echo "error: Android tests failed" >&2
  exit 1
fi
echo "$RESULT" | grep -E '^(OK \(|Time:)' || true
echo "Android tests passed"
