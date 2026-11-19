# Show the newest sandcastle run, or follow it while it is going.
#
# A run writes two logs under .sandcastle/logs/<stamp>/: `run.log`, one line per event for the whole
# run, and one transcript per agent session, named sandcastle-<branch>-<role>-step-<n>of<m>.log.
# `run.log` is the live view — it never rotates, so following it shows the run from first step to
# last. The transcripts are for reading one session's reasoning afterwards; --agent follows the
# newest of those, which switches file whenever a step ends.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOGS=".sandcastle/logs"
follow=0
list=0
agent=0
lines=60

usage() {
  echo "usage: npm run sandcastle:logs [-- [-f] [-n <lines>] [--list] [--agent]]"
  echo
  echo "  (no flags)   the newest run's run.log, last $lines lines"
  echo "  -f           follow it, for a run that is still going"
  echo "  -n <lines>   how much to show first"
  echo "  --list       every run, newest first"
  echo "  --agent      the newest agent transcript instead of run.log"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--follow) follow=1 ;;
    -n) lines="${2:-}"; shift ;;
    --list) list=1 ;;
    --agent) agent=1 ;;
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

# A run directory is a timestamped folder; the newest is the run that is going now.
shopt -s nullglob
runs=("$LOGS"/*/)
shopt -u nullglob

if [ "${#runs[@]}" -eq 0 ]; then
  echo "No sandcastle run under $LOGS." >&2
  echo "Start a run with: npm run sandcastle -- --issue <number>" >&2
  exit 1
fi

mapfile -t runs_newest_first < <(ls -1dt -- "${runs[@]}")

if [ "$list" -eq 1 ]; then
  printf '%s\n' "${runs_newest_first[@]}"
  exit 0
fi

newest_run="${runs_newest_first[0]}"

if [ "$agent" -eq 1 ]; then
  # Transcripts sit beside the run directories, named for the branch they belong to.
  transcripts=("$LOGS"/sandcastle-*.log)
  shopt -u nullglob
  if [ "${#transcripts[@]}" -eq 0 ]; then
    echo "No agent transcript under $LOGS." >&2
    exit 1
  fi
  mapfile -t newest_first < <(ls -1t -- "${transcripts[@]}")
  target="${newest_first[0]}"
else
  target="${newest_run}run.log"
fi

if [ ! -f "$target" ]; then
  echo "No log at $target." >&2
  exit 1
fi

# Say which file is being shown on stderr so a pipe stays clean.
echo "== ${target} (last ${lines} lines; --list for every run) ==" >&2

# A terminal gets the painted view; a pipe or a redirect gets the plain file, so `| grep` still works.
paint=()
if [ -t 1 ]; then paint=(--colour); fi
if [ "$follow" -eq 1 ]; then paint+=(--follow); fi

exec npx tsx .sandcastle/paint_log.mts "$target" "$lines" "${paint[@]}"
