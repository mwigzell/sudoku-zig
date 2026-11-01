#!/usr/bin/env bash
# Cross-entry parity drift check: every scenario in the shared file must run on both entries
# (native shell + web startup), be listed in the parity matrix, and any entry it skips must name
# the gap and an open issue. Also every core step kind must have a web step-runner case.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCENARIOS="src/test/fixtures/parity_scenarios.json"
NATIVE_RUNNER="src/native/shell/shell.zig"
WEB_RUNNER="src/wasm/flows/startup.test.mjs"
MATRIX="docs/parity-matrix.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "verify parity: jq required" >&2
  exit 1
fi

FAIL=0
violation() {
  echo "  • $1" >&2
  FAIL=1
}

for f in "$SCENARIOS" "$NATIVE_RUNNER" "$WEB_RUNNER" "$MATRIX"; do
  [[ -f "$f" ]] || violation "missing $f"
done
[[ $FAIL -eq 0 ]] || { echo "✗ parity drift check failed" >&2; exit 1; }

grep -q "test/fixtures/parity_scenarios.json" "$NATIVE_RUNNER" || violation "$NATIVE_RUNNER does not load $SCENARIOS"
grep -q "test/fixtures/parity_scenarios.json" "$WEB_RUNNER" || violation "$WEB_RUNNER does not load $SCENARIOS"
grep -q '^test "parity scenarios: ' "$NATIVE_RUNNER" || violation "$NATIVE_RUNNER has no parity scenarios test"
grep -q "node $WEB_RUNNER" build.zig || violation "$WEB_RUNNER is not in the glue test list"

if ! jq -e '.scenarios | length > 0' "$SCENARIOS" >/dev/null; then
  violation "$SCENARIOS has no scenarios"
fi
dupes="$(jq -r '.scenarios[].name' "$SCENARIOS" | sort | uniq -d)"
[[ -z "$dupes" ]] || violation "duplicate scenario names: $dupes"

while IFS= read -r name; do
  grep -q "\`$name\`" "$MATRIX" || violation "scenario $name is not listed in $MATRIX"
done < <(jq -r '.scenarios[].name' "$SCENARIOS")

while IFS=$'\t' read -r name entry gap issue; do
  [[ -z "$name" ]] && continue
  [[ "$entry" == "native" || "$entry" == "web" ]] || violation "scenario $name skips unknown entry '$entry'"
  [[ -n "$gap" && "$gap" != "null" ]] || violation "scenario $name skips $entry without naming the gap"
  if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    violation "scenario $name skips $entry without an issue number"
    continue
  fi
  state="$(gh issue view "$issue" --json state -q .state 2>/dev/null || echo UNKNOWN)"
  [[ "$state" == "OPEN" ]] || violation "scenario $name skips $entry under issue #$issue, which is $state (must be open)"
done < <(jq -r '.scenarios[] | select(.skip != null) | [.name, .skip.entry, (.skip.gap // ""), (.skip.issue // "" | tostring)] | @tsv' "$SCENARIOS")

STEP_ZIG="src/core/flow/step.zig"
STEP_RUNNER="src/wasm/flows/step_runner.js"
step_kinds="$(awk '/^pub const Step = union\(enum\) \{/ {on=1; next} on && /^\};/ {exit} on && /^    [a-z_]+[,:]/ {sub(/^    /, ""); sub(/[,:].*/, ""); print}' "$STEP_ZIG")"
[[ -n "$step_kinds" ]] || violation "no step kinds found in $STEP_ZIG"
while IFS= read -r kind; do
  [[ -z "$kind" ]] && continue
  const_name="$(grep -E "^export const STEP_[A-Z_]+ = \"$kind\";" "$STEP_RUNNER" | sed -E 's/^export const (STEP_[A-Z_]+).*/\1/')"
  if [[ -z "$const_name" ]]; then
    violation "step $kind has no STEP_* constant in $STEP_RUNNER"
  elif ! grep -q "case $const_name:" "$STEP_RUNNER"; then
    violation "step $kind has no case in $STEP_RUNNER"
  fi
done <<< "$step_kinds"

if [[ $FAIL -ne 0 ]]; then
  echo "✗ parity drift check failed — see $MATRIX" >&2
  exit 1
fi
echo "✓ parity: $(jq '.scenarios | length' "$SCENARIOS") scenario(s) on native and web"
