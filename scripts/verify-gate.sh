#!/usr/bin/env bash
# Time zig build verify-run, compare to docs/verify-timing.json, update last run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TIMING_FILE="$ROOT/docs/verify-timing.json"
REGRESSION_FACTOR="${VERIFY_REGRESSION_FACTOR:-1.5}"
TIME_LOG="$(mktemp)"

cleanup() {
  rm -f "$TIME_LOG"
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
regression_limit="$(awk -v last="$last" -v factor="$REGRESSION_FACTOR" 'BEGIN { printf "%.2f", last * factor }')"

verify_status=0
TIMEFORMAT='%R'
{ time { zig build verify-run || verify_status=$?; }; } 2> >(tee "$TIME_LOG" >&2)
elapsed="$(tail -1 "$TIME_LOG" | awk '{ printf "%.2f", $1 }')"

if [[ -z "$elapsed" ]]; then
  echo "verify timing: could not parse time output" >&2
  exit 1
fi

echo "── verify timing ──"
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
jq --argjson elapsed "$elapsed" --arg ts "$recorded_at" \
  '.last_seconds = $elapsed | .recorded_at = $ts' \
  "$TIMING_FILE" > "${TIMING_FILE}.tmp"
mv "${TIMING_FILE}.tmp" "$TIMING_FILE"
