# Sourced by the Android scripts: resolve SDK and JDK tools, debug-sign an APK, check release signing (no Gradle).
# Usage: resolve_android_tools <sdk_root> <min_api>; then ANDROID_JAR, AAPT, AAPT2, D8, ZIPALIGN, APKSIGNER, JAVAC, JAVA,
# JARSIGNER, KEYTOOL are set.

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
  AAPT2="$build_tools/aapt2"
  D8="$build_tools/d8"
  ZIPALIGN="$build_tools/zipalign"
  APKSIGNER="$build_tools/apksigner"
  for tool in "$AAPT" "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
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

  KEYTOOL="$(jdk_tool keytool)"
  JAVA="$(jdk_tool java)"
  JARSIGNER="$(jdk_tool jarsigner)"
}

# Usage: jdk_tool <name>; prints the JDK tool's path, from JAVA_HOME else PATH, or exits.
jdk_tool() {
  local tool=""
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/$1" ]]; then
    tool="$JAVA_HOME/bin/$1"
  else
    tool="$(command -v "$1" || true)"
  fi
  if [[ -z "$tool" || ! -x "$tool" ]]; then
    echo "error: $1 not found. Set JAVA_HOME to a JDK install." >&2
    exit 1
  fi
  echo "$tool"
}

# Usage: require_release_signing; checks the ANDROID_RELEASE_* variables and that the keystore opens with them.
# The passwords stay in the environment (jarsigner reads them with :env), never on a command line.
require_release_signing() {
  : "${ANDROID_RELEASE_KEY_PASS:=${ANDROID_RELEASE_STORE_PASS:-}}"
  export ANDROID_RELEASE_KEY_PASS
  local name
  for name in ANDROID_RELEASE_KEYSTORE ANDROID_RELEASE_STORE_PASS ANDROID_RELEASE_KEY_ALIAS ANDROID_RELEASE_KEY_PASS; do
    if [[ -z "${!name:-}" ]]; then
      echo "error: $name is required for release signing" >&2
      exit 1
    fi
  done
  if [[ ! -f "$ANDROID_RELEASE_KEYSTORE" ]]; then
    echo "error: release keystore does not exist: $ANDROID_RELEASE_KEYSTORE" >&2
    exit 1
  fi
  if ! "$KEYTOOL" -list -keystore "$ANDROID_RELEASE_KEYSTORE" -storepass:env ANDROID_RELEASE_STORE_PASS \
    -alias "$ANDROID_RELEASE_KEY_ALIAS" >/dev/null 2>&1; then
    echo "error: the release keystore does not open with ANDROID_RELEASE_STORE_PASS, or has no key ANDROID_RELEASE_KEY_ALIAS" >&2
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

# Usage: sha256_of <file>; prints its SHA-256 (sha256sum on Linux, shasum on macOS).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "error: neither sha256sum nor shasum found" >&2
    exit 1
  fi
}

# Usage: resolve_bundletool <repo_root>; sets BUNDLETOOL_JAR. bundletool is not in the SDK: the pinned jar is fetched
# once into third_party/bundletool/ and its hash is checked on every run.
resolve_bundletool() {
  local version="1.18.3"
  local sha256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
  BUNDLETOOL_JAR="$1/third_party/bundletool/bundletool-all-$version.jar"
  if [[ ! -f "$BUNDLETOOL_JAR" ]]; then
    echo "fetching bundletool $version"
    mkdir -p "$(dirname "$BUNDLETOOL_JAR")"
    curl -fsSL -o "$BUNDLETOOL_JAR.part" "https://github.com/google/bundletool/releases/download/$version/bundletool-all-$version.jar"
    mv "$BUNDLETOOL_JAR.part" "$BUNDLETOOL_JAR"
  fi
  local actual
  actual="$(sha256_of "$BUNDLETOOL_JAR")"
  if [[ "$actual" != "$sha256" ]]; then
    echo "error: $BUNDLETOOL_JAR sha256 is $actual, expected $sha256" >&2
    exit 1
  fi
}
