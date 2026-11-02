# Sourced by the Android scripts: resolve SDK tools and debug-sign an APK (no Gradle).
# Usage: resolve_android_tools <sdk_root> <min_api>; then ANDROID_JAR, AAPT, D8, ZIPALIGN, APKSIGNER, JAVAC, KEYTOOL are set.

pick_latest_dir() {
  ls -1 "$1" 2>/dev/null | sort -V | awk 'NF {v=$0} END {print v}'
}

resolve_android_tools() {
  local sdk_root="$1"
  local min_api="$2"

  local platform_dir
  platform_dir="$(pick_latest_dir "$sdk_root/platforms")"
  case "$platform_dir" in
    android-*)
      PLATFORM_API="${platform_dir#android-}"
      ;;
    *)
      echo "error: no Android platform found under $sdk_root/platforms (expected android-<api>)" >&2
      exit 1
      ;;
  esac

  local platform_api_int="${PLATFORM_API%%.*}"
  if [[ "$platform_api_int" -lt "$min_api" ]]; then
    echo "error: newest Android platform api ($PLATFORM_API) is below required $min_api" >&2
    exit 1
  fi

  ANDROID_JAR="$sdk_root/platforms/$platform_dir/android.jar"
  if [[ ! -f "$ANDROID_JAR" ]]; then
    echo "error: missing Android platform jar: $ANDROID_JAR" >&2
    exit 1
  fi

  local build_tools_version
  build_tools_version="$(pick_latest_dir "$sdk_root/build-tools")"
  if [[ -z "$build_tools_version" ]]; then
    echo "error: no Android build-tools found under $sdk_root/build-tools" >&2
    exit 1
  fi

  local build_tools="$sdk_root/build-tools/$build_tools_version"
  AAPT="$build_tools/aapt"
  D8="$build_tools/d8"
  ZIPALIGN="$build_tools/zipalign"
  APKSIGNER="$build_tools/apksigner"
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
}

# Usage: sign_debug_apk <aligned_apk> <out_apk>; creates the debug keystore on first use.
sign_debug_apk() {
  local debug_keystore="${ANDROID_DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
  if [[ ! -f "$debug_keystore" ]]; then
    mkdir -p "$(dirname "$debug_keystore")"
    "$KEYTOOL" -genkeypair -v \
      -keystore "$debug_keystore" \
      -storepass android \
      -alias androiddebugkey \
      -keypass android \
      -keyalg RSA \
      -keysize 2048 \
      -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US"
  fi

  "$APKSIGNER" sign \
    --ks "$debug_keystore" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    --out "$2" \
    "$1"
}
