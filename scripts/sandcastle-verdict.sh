#!/usr/bin/env bash
# Print the reviewer's verdict for the one finished sandcastle run, so it can be
# read before the work is merged or dropped. Changes nothing.
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

echo "Run:      $BRANCH"
echo "Base:     $CURRENT"
echo "Commits:  $(git rev-list --count "$CURRENT..$BRANCH")"
echo

reviewer_log="$(ls -1t .sandcastle/logs/*"$STAMP"*reviewer*.log 2>/dev/null | head -1 || true)"
if [ -n "$reviewer_log" ]; then
  echo "Reviewer log: $reviewer_log"
  echo "-------------------------------------------------------------------"
  cat "$reviewer_log"
  echo "-------------------------------------------------------------------"
else
  echo "No reviewer log for $STAMP. Logs present:"
  ls -1 .sandcastle/logs 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo "-------------------------------------------------------------------"
fi

echo
echo "Diff against $CURRENT:"
git --no-pager diff --stat "$CURRENT...$BRANCH"
