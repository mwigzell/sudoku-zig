#!/usr/bin/env bash
# Accept the one finished sandcastle run: show the reviewer's verdict, then merge
# its branch into the current branch and remove the run's worktree and branch.
# There is only ever one run branch; more or fewer means the repo is not settled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CURRENT="$(git rev-parse --abbrev-ref HEAD)"

branches=()
while IFS= read -r b; do
  [ -n "$b" ] && branches+=("$b")
done < <(git branch --list 'sandcastle/*' --format='%(refname:short)')

if [ "${#branches[@]}" -eq 0 ]; then
  echo "No sandcastle run to accept." >&2
  exit 1
fi
if [ "${#branches[@]}" -gt 1 ]; then
  echo "More than one sandcastle branch; settle these first:" >&2
  printf '  %s\n' "${branches[@]}" >&2
  exit 1
fi

BRANCH="${branches[0]}"
SLUG="${BRANCH#sandcastle/}"

echo "Run:     $BRANCH"
echo "Commits: $(git rev-list --count "$CURRENT..$BRANCH") on top of $CURRENT"
echo

reviewer_log="$(ls -1t .sandcastle/logs/*reviewer*.log 2>/dev/null | head -1 || true)"
if [ -n "$reviewer_log" ]; then
  echo "Reviewer verdict ($reviewer_log):"
  echo "-------------------------------------------------------------------"
  # The reviewer ends with its criterion/evidence table; the tail is the verdict.
  tail -n 60 "$reviewer_log"
  echo "-------------------------------------------------------------------"
else
  echo "No reviewer log found; read the diff before accepting:" >&2
  git --no-pager diff --stat "$CURRENT...$BRANCH" >&2
fi
echo
echo "Diff:"
git --no-pager diff --stat "$CURRENT...$BRANCH"
echo

read -r -p "Merge $BRANCH into $CURRENT, then remove its worktree and branch? [y/N] " reply
case "$reply" in
  [yY]) ;;
  *) echo "Nothing done." ; exit 1 ;;
esac

git merge --no-edit "$BRANCH"
git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
  /^worktree / { wt = substr($0, 10) }
  $0 == "branch " b { print wt }
' | while IFS= read -r wt; do
  [ -n "$wt" ] && git worktree remove --force "$wt"
done
git branch -d "$BRANCH"

echo "Accepted $BRANCH into $CURRENT."
