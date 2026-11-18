#!/usr/bin/env bash
# Accept the one finished sandcastle run: merge its branch into the current
# branch, then remove its worktree and its branch. Reading the reviewer report
# first is `sandcastle:verdict`; discarding a run instead is `sandcastle:drop`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. scripts/lib/sandcastle-run.sh

sandcastle_branches
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "No sandcastle run to accept." >&2
  exit 1
fi
sandcastle_one_branch

BRANCH="${BRANCHES[0]}"

# The record names the branch's own head and the commit it was cut from, so both are read before
# the merge moves the current branch forward.
BASE="$(git rev-parse "$CURRENT")"
HEAD_SHA="$(git rev-parse "$BRANCH")"

# The worktree may hold the only copy of a later fix, so refuse rather than lose it.
worktree="$(sandcastle_worktree "$BRANCH")"
if [ -n "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain)" ]; then
  echo "The run's worktree has uncommitted changes: $worktree" >&2
  git -C "$worktree" status --short >&2
  exit 1
fi

# The device check runs before the merge: refusing inside the close path would leave the branch
# already merged, with nothing left to hold back. The close path asks the same question again.
if ! npx tsx .sandcastle/accept.mts --check --stamp "${BRANCH##*/}" --branch "$BRANCH" --into "$CURRENT" --base "$BASE" --head "$HEAD_SHA"; then
  echo "Refused $BRANCH: it is not merged, and its worktree and branch are left as they are." >&2
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
# the issue it aimed at closes nothing, and an unclosed issue is a failed accept rather than a
# success with a footnote.
if ! npx tsx .sandcastle/accept.mts --stamp "${BRANCH##*/}" --branch "$BRANCH" --into "$CURRENT" --base "$BASE" --head "$HEAD_SHA"; then
  echo "Accepted $BRANCH into $CURRENT, but the run record or the issue close did not finish: see above." >&2
  exit 1
fi
echo "Accepted $BRANCH into $CURRENT."
