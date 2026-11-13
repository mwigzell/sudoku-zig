#!/usr/bin/env bash
# Show the newest sandcastle transcript, or follow it while a run is going.
#
# A run writes one transcript per agent session under .sandcastle/logs/, named
# sandcastle-<branch>-<role>-step-<n>of<m>.log. The newest one is the session that is running
# now, so this is the live view of a run; --list shows every transcript the harness still holds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOGS=".sandcastle/logs"
follow=0
list=0
lines=60

usage() {
  echo "usage: npm run sandcastle:logs [-- [-f] [-n <lines>] [--list]]"
  echo
  echo "  (no flags)   the newest transcript, last $lines lines"
  echo "  -f           follow it, for a run that is still going"
  echo "  -n <lines>   how much of the transcript to show first"
  echo "  --list       every transcript, newest first"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--follow) follow=1 ;;
    -n) lines="${2:-}"; shift ;;
    --list) list=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
  echo "-n needs a line count, for example: -n 200" >&2
  exit 1
fi

shopt -s nullglob
transcripts=("$LOGS"/sandcastle-*.log)
shopt -u nullglob

if [ "${#transcripts[@]}" -eq 0 ]; then
  echo "No sandcastle transcript under $LOGS." >&2
  echo "Start a run with: npm run sandcastle -- --issue <number>" >&2
  exit 1
fi

# Newest first: the transcript still being written is the top of the list.
mapfile -t newest_first < <(ls -1t -- "${transcripts[@]}")

if [ "$list" -eq 1 ]; then
  printf '%s\n' "${newest_first[@]}"
  exit 0
fi

newest="${newest_first[0]}"
# Say which file is being shown, and how many the harness holds, on stderr so a pipe stays clean.
echo "== ${newest} (last ${lines} lines of ${#transcripts[@]} transcript(s)) ==" >&2

if [ "$follow" -eq 1 ]; then
  exec tail -n "$lines" -f -- "$newest"
fi
tail -n "$lines" -- "$newest"
