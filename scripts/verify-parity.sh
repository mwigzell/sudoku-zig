#!/usr/bin/env bash
# Cross-entry parity drift check: every scenario in the shared file must run on both entries
# (native shell + web shell), be listed in the parity matrix, and any entry it skips must name
# the gap and an open issue.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCENARIOS="src/test/parity/scenarios.json"
NATIVE_RUNNER="src/native/shell/parity_test.zig"
WEB_RUNNER="src/wasm/parity.test.mjs"
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

grep -q "test/parity/scenarios.json" "$NATIVE_RUNNER" || violation "$NATIVE_RUNNER does not load $SCENARIOS"
grep -q "test/parity/scenarios.json" "$WEB_RUNNER" || violation "$WEB_RUNNER does not load $SCENARIOS"
grep -q '@import("parity_test.zig")' src/native/shell/shell.zig || violation "$NATIVE_RUNNER is not in the native test graph"
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

if [[ $FAIL -ne 0 ]]; then
  echo "✗ parity drift check failed — see $MATRIX" >&2
  exit 1
fi
echo "✓ parity: $(jq '.scenarios | length' "$SCENARIOS") scenario(s) on native and web"
