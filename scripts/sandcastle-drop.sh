#!/usr/bin/env bash
# Throw away the one finished sandcastle run: remove its worktree and delete its
# branch, with no merge. Refuses when the repo holds anything but one run branch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. scripts/lib/sandcastle-run.sh

sandcastle_branches
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "No sandcastle run to drop." >&2
  exit 1
fi
sandcastle_one_branch

BRANCH="${BRANCHES[0]}"

echo "Run:     $BRANCH"
echo "Commits: $(git rev-list --count "HEAD..$BRANCH") (discarded)"
echo
if ! read -r -p "Remove $BRANCH, its worktree and its commits, with no merge? [y/N] " reply; then
  echo "Nothing done."
  exit 1
fi
case "$reply" in
  [yY]) ;;
  *) echo "Nothing done." ; exit 1 ;;
esac

# The worktree may hold the only copy of a later fix, so refuse rather than lose it.
worktree="$(sandcastle_worktree "$BRANCH")"
if [ -n "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain)" ]; then
  echo "The run's worktree has uncommitted changes: $worktree" >&2
  git -C "$worktree" status --short >&2
  exit 1
fi

# Take the run's ticks back off the issue before the branch goes: the record of what it
# wrote lives in the run's log directory, named after the stamp the branch ends with.
npx tsx .sandcastle/drop.mts --stamp "${BRANCH##*/}"

if [ -n "$worktree" ]; then
  git worktree remove --force "$worktree"
fi
git branch -D "$BRANCH"

echo "Dropped $BRANCH."
