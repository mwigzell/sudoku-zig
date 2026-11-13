#!/usr/bin/env bash
# Throw away the one finished sandcastle run: remove its worktree and delete its
# branch, with no merge. Refuses when the repo holds anything but one run branch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

branches=()
while IFS= read -r b; do
  [ -n "$b" ] && branches+=("$b")
done < <(git branch --list 'sandcastle/*' --format='%(refname:short)')

if [ "${#branches[@]}" -eq 0 ]; then
  echo "No sandcastle run to drop." >&2
  exit 1
fi
if [ "${#branches[@]}" -gt 1 ]; then
  echo "More than one sandcastle branch; settle these first:" >&2
  printf '  %s\n' "${branches[@]}" >&2
  exit 1
fi

BRANCH="${branches[0]}"

echo "Run:     $BRANCH"
echo "Commits: $(git rev-list --count "HEAD..$BRANCH") (discarded)"
echo
read -r -p "Remove $BRANCH, its worktree and its commits, with no merge? [y/N] " reply
case "$reply" in
  [yY]) ;;
  *) echo "Nothing done." ; exit 1 ;;
esac

# Take the run's ticks back off the issue before the branch goes: the record of what it
# wrote lives in the run's log directory, named after the stamp the branch ends with.
npx tsx .sandcastle/drop.mts --stamp "${BRANCH##*/}"

git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
  /^worktree / { wt = substr($0, 10) }
  $0 == "branch " b { print wt }
' | while IFS= read -r wt; do
  [ -n "$wt" ] && git worktree remove --force "$wt"
done
git branch -D "$BRANCH"

echo "Dropped $BRANCH."
