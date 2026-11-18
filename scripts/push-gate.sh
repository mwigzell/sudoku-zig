#!/usr/bin/env bash
# Push gate: the lanes a push must prove, cheapest first, stopping at the first failure.
#
# `zig build verify` is device-free by design, so the device suite lives here and only here; a push
# waits for this run's record. Each lane's status is written to `.zig-cache/push-gate/<commit>.json`
# even when a lane fails, so a red push has a record rather than a transcript.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The per-lane commands, overridable so the gate's own suite can drive a lane without a device for
# minutes. The defaults are the gates a push must pass, ordered by cost: nothing cheaper can be
# proven by a lane that has not run yet, and the device lane is last.
LANE_NAMES=(verify verify-slow android-device)
LANE_CMDS=(
  "${PUSH_GATE_VERIFY_CMD:-zig build verify}"
  "${PUSH_GATE_SLOW_CMD:-zig build verify-slow}"
  "${PUSH_GATE_DEVICE_CMD:-zig build android-test}"
)
RECORD_DIR="${PUSH_GATE_RECORD_DIR:-$ROOT/.zig-cache/push-gate}"

if ! command -v jq >/dev/null 2>&1; then
  echo "push gate: jq required" >&2
  exit 1
fi

# `--lanes` prints what this gate would run and stops: the lane table a reader reads, no workload.
if [[ "${1:-}" == "--lanes" ]]; then
  for i in "${!LANE_NAMES[@]}"; do
    jq -nc --arg name "${LANE_NAMES[$i]}" --arg command "${LANE_CMDS[$i]}" '{name: $name, command: $command}'
  done | jq -s '.'
  exit 0
fi

commit="$(git rev-parse HEAD)" || {
  echo "push gate: cannot read HEAD, so the record could not name the commit it proved" >&2
  exit 1
}
mkdir -p "$RECORD_DIR" || {
  echo "push gate: cannot create the record directory $RECORD_DIR" >&2
  exit 1
}
record="$RECORD_DIR/$commit.json"

lanes_json="$(mktemp)"
trap 'rm -f "$lanes_json"' EXIT

result=passed
for i in "${!LANE_NAMES[@]}"; do
  name="${LANE_NAMES[$i]}"
  cmd="${LANE_CMDS[$i]}"
  status=skipped
  duration=null
  # Lanes after a failure stay skipped: the run is already red, and the device lane costs minutes.
  if [[ "$result" == "passed" ]]; then
    echo "── push gate: $name ($cmd) ──"
    SECONDS=0
    if bash -o pipefail -c "$cmd"; then
      status=passed
    else
      status=failed
      result=failed
    fi
    duration=$SECONDS
  fi
  jq -nc --arg name "$name" --arg command "$cmd" --arg status "$status" --argjson duration "$duration" \
    '{name: $name, command: $command, status: $status, duration_s: $duration}' >> "$lanes_json"
done

jq -s --arg commit "$commit" --arg result "$result" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{commit: $commit, result: $result, at: $at, lanes: .}' "$lanes_json" > "$record" || {
  echo "push gate: cannot write the record $record" >&2
  exit 1
}

echo
if [[ "$result" == "passed" ]]; then
  echo "✓ push gate passed; per-lane record $record"
  exit 0
fi
echo "✗ push gate failed; per-lane record $record" >&2
exit 1
