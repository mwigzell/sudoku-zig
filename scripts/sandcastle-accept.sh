#!/usr/bin/env bash
# Accept the one finished sandcastle run: merge its branch into the current
# branch, then remove its worktree and its branch. Reading the reviewer report
# first is `sandcastle:verdict`; discarding a run instead is `sandcastle:drop`.
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

# The worktree may hold the only copy of a later fix, so refuse rather than lose it.
worktree="$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
  /^worktree / { wt = substr($0, 10) }
  $0 == "branch " b { print wt }
')"
if [ -n "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain)" ]; then
  echo "The run's worktree has uncommitted changes: $worktree" >&2
  git -C "$worktree" status --short >&2
  exit 1
fi

echo "Merging $BRANCH ($(git rev-list --count "$CURRENT..$BRANCH") commit(s)) into $CURRENT"
git merge --no-edit "$BRANCH"

if [ -n "$worktree" ]; then
  git worktree remove --force "$worktree"
fi
git branch -d "$BRANCH"

# Accepting ends the issue: the run already proved its criteria, and this is the human's yes.
# Closing is the host's write, so it goes through the same path as a tick. A run with no record of
# the issue it aimed at closes nothing and says so, rather than guessing a number.
if npx tsx .sandcastle/accept.mts --stamp "${BRANCH##*/}" --branch "$BRANCH" --into "$CURRENT"; then
  echo "Accepted $BRANCH into $CURRENT."
else
  echo "Accepted $BRANCH into $CURRENT, but the issue was not closed: close it by hand." >&2
fi
