#!/usr/bin/env bash
# Generator experiment — not part of zig build verify.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LIMIT="${BENCH_PUZZLE_GEN_SECONDS:-60}"
exec "$ROOT/scripts/run-with-timeout.sh" "$LIMIT" \
  zig test src/puzzle_gen/bench.zig -lc --test-filter 'bench: one dig-hole'
