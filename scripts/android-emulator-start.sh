#!/usr/bin/env bash
# Start the agent's own headless emulator for `zig build android-test`, and wait until it has booted.
# It uses a clone of the developer's AVD on its own port, so a device open in Android Studio is never touched.
set -euo pipefail

AVD="${1:-Agent_API_30}"
PORT="${2:-5556}"
SERIAL="emulator-$PORT"
BOOT_TIMEOUT_S="${BOOT_TIMEOUT_S:-300}"

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK_ROOT" ]]; then
  echo "error: ANDROID_HOME (or ANDROID_SDK_ROOT) is not set" >&2
  exit 1
fi
EMULATOR="$SDK_ROOT/tools/emulator"
ADB="$SDK_ROOT/platform-tools/adb"
for tool in "$EMULATOR" "$ADB"; do
  if [[ ! -x "$tool" ]]; then
    echo "error: not executable: $tool" >&2
    exit 1
  fi
done

# Several devices may be attached; tests and the gate target one by serial (`ANDROID_SERIAL`).
if "$ADB" devices | tail -n +2 | grep -q "device$"; then
  echo "note: other devices are connected; this one is launched on $SERIAL, so name it when targeting a run" >&2
fi

echo "starting $AVD on $SERIAL (headless, software GPU)"
nohup "$EMULATOR" -avd "$AVD" -port "$PORT" \
  -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot \
  >"/tmp/android-emulator-$PORT.log" 2>&1 &

waited=0
while :; do
  if [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
    break
  fi
  if (( waited >= BOOT_TIMEOUT_S )); then
    echo "error: $SERIAL did not boot within ${BOOT_TIMEOUT_S}s; log: /tmp/android-emulator-$PORT.log" >&2
    exit 1
  fi
  sleep 3
  waited=$(( waited + 3 ))
done

echo "$SERIAL ready after ${waited}s — log: /tmp/android-emulator-$PORT.log"
echo "note: the device is still busy for a minute after boot; runs started immediately take far longer"
