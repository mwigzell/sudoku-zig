#!/usr/bin/env bash
# Time zig build verify-run and enforce timing policy from docs/verify-timing.json.
# Compile first without timing (verify-build), so the measurement is the test workload, not cache state.
# Persist last successful timing to local state (untracked), not to policy file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TIMING_FILE="$ROOT/docs/verify-timing.json"
STATE_FILE="${VERIFY_TIMING_STATE_FILE:-$ROOT/.zig-cache/verify-timing-local.json}"
REGRESSION_FACTOR="${VERIFY_REGRESSION_FACTOR:-1.5}"
TIME_LOG="$(mktemp)"
WARMUP_LOG="$(mktemp)"

cleanup() {
  rm -f "$TIME_LOG" "$WARMUP_LOG"
}
trap cleanup EXIT

if [[ ! -f "$TIMING_FILE" ]]; then
  echo "verify timing: missing $TIMING_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "verify timing: jq required" >&2
  exit 1
fi

budget="$(jq -r '.budget_seconds' "$TIMING_FILE")"
last="$(jq -r '.last_seconds // .budget_seconds' "$TIMING_FILE")"
if [[ -f "$STATE_FILE" ]]; then
  last="$(jq -r '.last_seconds // empty' "$STATE_FILE")"
  if [[ -z "$last" || "$last" == "null" ]]; then
    last="$(jq -r '.last_seconds // .budget_seconds' "$TIMING_FILE")"
  fi
fi
regression_limit="$(awk -v last="$last" -v factor="$REGRESSION_FACTOR" 'BEGIN { printf "%.2f", last * factor }')"

# The timed runs are their own `zig build` invocations, so a parity window declared on the outer one
# has to travel in the environment; without the flag the argument list is empty and nothing changes.
parity_args=()
if [[ -n "${SUDOKU_PARITY_OFF:-}" ]]; then
  parity_args=(-Dparity=off "-Dparity-off-issue=$SUDOKU_PARITY_OFF")
fi

# Untimed: a cold cache must not read as a suite slowdown.
warmup_status=0
TIMEFORMAT='%R'
{ time { zig build verify-build "${parity_args[@]}" || warmup_status=$?; }; } 2> >(tee "$WARMUP_LOG" >&2)
warmup_elapsed="$(tail -1 "$WARMUP_LOG" | awk '{ printf "%.2f", $1 }')"
if [[ "$warmup_status" -ne 0 ]]; then
  echo "verify timing: warm-up build failed" >&2
  exit "$warmup_status"
fi

verify_status=0
TIMEFORMAT='%R'
{ time { zig build verify-run "${parity_args[@]}" || verify_status=$?; }; } 2> >(tee "$TIME_LOG" >&2)
elapsed="$(tail -1 "$TIME_LOG" | awk '{ printf "%.2f", $1 }')"

if [[ -z "$elapsed" ]]; then
  echo "verify timing: could not parse time output" >&2
  exit 1
fi

echo "── verify timing ──"
echo " warm-up:  ${warmup_elapsed}s (untimed build)"
echo " run:      ${elapsed}s"
echo " last:     ${last}s"
echo " budget:   ${budget}s"
echo " regress:  >${regression_limit}s (${REGRESSION_FACTOR}x last) fails"

if [[ "$verify_status" -ne 0 ]]; then
  echo "verify timing: verify-run failed in ${elapsed}s" >&2
  exit "$verify_status"
fi

failed=0
if awk -v e="$elapsed" -v b="$budget" 'BEGIN { exit (e > b) ? 0 : 1 }'; then
  echo "✗ FAILED over budget (${elapsed}s > ${budget}s)" >&2
  echo "  bump docs/verify-timing.json budget_seconds if the suite legitimately grew" >&2
  failed=1
elif awk -v e="$elapsed" -v r="$regression_limit" 'BEGIN { exit (e > r) ? 0 : 1 }'; then
  echo "✗ FAILED regression (${elapsed}s > ${regression_limit}s vs last ${last}s)" >&2
  echo "  fix the slowdown or update docs/verify-timing.json after intentional change" >&2
  failed=1
else
  echo "✓ PASSED timing gate"
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

recorded_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
mkdir -p "$(dirname "$STATE_FILE")"
jq -n --argjson elapsed "$elapsed" --arg ts "$recorded_at" \
  '{last_seconds: $elapsed, recorded_at: $ts}' \
  > "$STATE_FILE"
