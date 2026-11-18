#!/usr/bin/env bash
# Guard for the step-scoped parity window (ADR-0022 §3): the cross-front-end check may be omitted
# from the gate only for an issue that is still open, and only when that issue is named. Anything
# else exits non-zero, so an incomplete window or an expired one cannot quietly keep parity off.
#
# Usage: verify-parity-off.sh <issue>    (an empty argument is what a build passes when the flag
# naming the issue was left out, which is refused.)
set -euo pipefail

issue="${1:-}"

if [[ -z "$issue" ]]; then
  echo "verify parity: -Dparity=off needs -Dparity-off-issue=<N>, the open issue whose steps run without the parity check" >&2
  exit 1
fi

if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
  echo "verify parity: -Dparity-off-issue must be an issue number, not '$issue'" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "verify parity: gh required to check issue #$issue is open" >&2
  exit 1
fi

state="$(gh issue view "$issue" --json state -q .state 2>/dev/null || echo UNKNOWN)"
if [[ "$state" != "OPEN" ]]; then
  echo "✗ parity: issue #$issue is $state, so the window it would open is not live — parity stays on" >&2
  exit 1
fi

echo "── parity OFF (#$issue) ──"
