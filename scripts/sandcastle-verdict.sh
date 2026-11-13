#!/usr/bin/env bash
# Print one readable block per step of the one finished sandcastle run, then what the
# branch changed. Changes nothing: merging is `sandcastle:accept`, discarding is
# `sandcastle:drop`. The reviewer's full transcript stays under the run's log directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CURRENT="$(git rev-parse --abbrev-ref HEAD)"

branches=()
while IFS= read -r b; do
  [ -n "$b" ] && branches+=("$b")
done < <(git branch --list 'sandcastle/*' --format='%(refname:short)')

if [ "${#branches[@]}" -eq 0 ]; then
  echo "No sandcastle run to review." >&2
  exit 1
fi
if [ "${#branches[@]}" -gt 1 ]; then
  echo "More than one sandcastle branch; settle these first:" >&2
  printf '  %s\n' "${branches[@]}" >&2
  exit 1
fi

BRANCH="${branches[0]}"
# Run branches are sandcastle/<template>/<timestamp>; the logs carry the same stamp.
STAMP="$(basename "$BRANCH")"
RUN_LOGS=".sandcastle/logs/$STAMP"

echo "Run:      $BRANCH"
echo "Base:     $CURRENT"
echo "Commits:  $(git rev-list --count "$CURRENT..$BRANCH")"
echo

shopt -s nullglob
verdicts=("$RUN_LOGS"/step-*-verdict.json)
shopt -u nullglob

if [ "${#verdicts[@]}" -eq 0 ]; then
  echo "No step verdicts under $RUN_LOGS."
else
  for verdict in "${verdicts[@]}"; do
    step="$(basename "$verdict")"
    step="${step#step-}"
    node .sandcastle/report.mts "${step%%-*}" "$verdict"
    echo
  done
fi

if [ -f "$RUN_LOGS/final-verdict.json" ]; then
  node .sandcastle/report.mts --final "$RUN_LOGS/final-verdict.json"
  echo
else
  echo "The whole-branch review did not run: no final-verdict.json under $RUN_LOGS."
  echo
fi

echo "What the branch changes ($CURRENT...$BRANCH):"
git --no-pager diff --stat "$CURRENT...$BRANCH" | sed 's/^/  /'
echo
echo "Reviewer transcripts: $RUN_LOGS/"
echo "Accept it:  npm run sandcastle:accept"
echo "Drop it:    npm run sandcastle:drop"
