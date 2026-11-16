#!/usr/bin/env bash
# sandcastle-run.sh — the preamble the accept, drop and verdict scripts share.
#
# Sourced after the caller has moved to the repo root. It discovers the unaccepted run branch,
# refuses when the repo holds more than one, and resolves the worktree that holds a branch.
# The caller owns the wording for "there is no run", because each verb says it differently.

CURRENT="$(git rev-parse --abbrev-ref HEAD)"

# Every sandcastle run branch in the repo, in the order git lists them.
sandcastle_branches() {
  BRANCHES=()
  while IFS= read -r branch; do
    [ -n "$branch" ] && BRANCHES+=("$branch")
  done < <(git branch --list 'sandcastle/*' --format='%(refname:short)')
}

# Refuse when more than one run branch remains; leave the single one in BRANCH.
sandcastle_one_branch() {
  if [ "${#BRANCHES[@]}" -gt 1 ]; then
    echo "More than one sandcastle branch; settle these first:" >&2
    printf '  %s\n' "${BRANCHES[@]}" >&2
    exit 1
  fi
  BRANCH="${BRANCHES[0]}"
}

# The worktree that holds branch `$1`, or nothing when that branch is not checked out.
sandcastle_worktree() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == "branch " b { print wt }
  '
}
