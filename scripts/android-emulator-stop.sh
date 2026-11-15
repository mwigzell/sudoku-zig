#!/usr/bin/env bash
# Stop the agent's headless emulator started by scripts/android-emulator-start.sh, and wait until adb drops it.
set -euo pipefail

PORT="${1:-5556}"
SERIAL="emulator-$PORT"
GONE_TIMEOUT_S="${GONE_TIMEOUT_S:-60}"

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK_ROOT" ]]; then
  echo "error: ANDROID_HOME (or ANDROID_SDK_ROOT) is not set" >&2
  exit 1
fi
ADB="$SDK_ROOT/platform-tools/adb"
if [[ ! -x "$ADB" ]]; then
  echo "error: not executable: $ADB" >&2
  exit 1
fi

if ! "$ADB" devices | tail -n +2 | grep -q "^$SERIAL"; then
  echo "$SERIAL is not connected; nothing to stop"
  exit 0
fi

# `emu kill` is the graceful path; a device that does not answer is left for the caller to inspect.
"$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || echo "warning: $SERIAL did not accept emu kill" >&2

waited=0
while "$ADB" devices | tail -n +2 | grep -q "^$SERIAL"; do
  if (( waited >= GONE_TIMEOUT_S )); then
    echo "error: $SERIAL was still listed after ${GONE_TIMEOUT_S}s" >&2
    exit 1
  fi
  sleep 2
  waited=$(( waited + 2 ))
done

echo "$SERIAL stopped after ${waited}s"
