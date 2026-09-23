#!/usr/bin/env bash
# Time zig build verify-run, compare to docs/verify-timing.json, update last run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TIMING_FILE="$ROOT/docs/verify-timing.json"
TIME_LOG="$(mktemp)"
REGRESSION_FACTOR="${VERIFY_REGRESSION_FACTOR:-1.5}"

cleanup() {
  rm -f "$TIME_LOG"
}
trap cleanup EXIT

if [[ ! -f "$TIMING_FILE" ]]; then
  echo "verify timing: missing $TIMING_FILE" >&2
  exit 1
fi

/usr/bin/time -p -o "$TIME_LOG" zig build verify-run
verify_status=$?

elapsed="$(
  python3 - "$TIME_LOG" <<'PY'
import sys
real = None
with open(sys.argv[1]) as f:
    for line in f:
        if line.startswith("real "):
            real = float(line.split()[1])
            break
if real is None:
    raise SystemExit("verify timing: could not parse /usr/bin/time output")
print(f"{real:.2f}")
PY
)"

if [[ "$verify_status" -ne 0 ]]; then
  echo "verify timing: verify-run failed in ${elapsed}s" >&2
  exit "$verify_status"
fi

python3 - "$TIMING_FILE" "$elapsed" "$REGRESSION_FACTOR" <<'PY'
import datetime
import json
import sys

path, elapsed_s, factor_s = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
with open(path) as f:
    data = json.load(f)

budget = float(data["budget_seconds"])
last = float(data.get("last_seconds", budget))
regression_limit = last * factor_s

print(f"── verify timing ──")
print(f" run:      {elapsed_s:.2f}s")
print(f" last:     {last:.2f}s")
print(f" budget:   {budget:.2f}s")
print(f" regress:  >{regression_limit:.2f}s ({factor_s}x last) fails")

failed = False
if elapsed_s > budget:
    print(f"✗ FAILED over budget ({elapsed_s:.2f}s > {budget:.2f}s)", file=sys.stderr)
    print("  bump docs/verify-timing.json budget_seconds if the suite legitimately grew", file=sys.stderr)
    failed = True
elif elapsed_s > regression_limit:
    print(f"✗ FAILED regression ({elapsed_s:.2f}s > {regression_limit:.2f}s vs last {last:.2f}s)", file=sys.stderr)
    print("  fix the slowdown or update docs/verify-timing.json after intentional change", file=sys.stderr)
    failed = True
else:
    print("✓ PASSED timing gate")

if failed:
    sys.exit(1)

data["last_seconds"] = round(elapsed_s, 2)
data["recorded_at"] = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
