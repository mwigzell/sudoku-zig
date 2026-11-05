#!/usr/bin/env bash
# Mechanical standards gate for changed source — encodes AGENTS.md and CONTEXT.md
# rules that grep can enforce (DRY/architecture/SOLID
# judgement calls still belong in human or two-axis review).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- terminal styling (unicode always; color when TTY or forced) ---
USE_COLOR=0
if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]] || [[ -n "${VERIFY_STANDARDS_COLOR:-}" ]]; }; then
  USE_COLOR=1
fi
if [[ $USE_COLOR -eq 1 ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN="" C_RED="" C_YELLOW="" C_BOLD="" C_DIM="" C_RESET=""
fi

MARK_OK="✓"
MARK_FAIL="✗"

banner() {
  printf '%b\n' "${C_BOLD}── standards gate ──${C_RESET}"
}

pass_line() {
  printf '%b %b %s\n' "${C_GREEN}${MARK_OK}${C_RESET}" "${C_BOLD}PASSED${C_RESET}" "$1"
}

fail_line() {
  printf '%b %b %s\n' "${C_RED}${MARK_FAIL}${C_RESET}" "${C_BOLD}FAILED${C_RESET}" "$1" >&2
}

BASE="${VERIFY_BASE:-}"
if [[ -z "$BASE" ]]; then
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    BASE="$(git merge-base HEAD origin/main)"
  elif git rev-parse --verify main >/dev/null 2>&1; then
    BASE="$(git merge-base HEAD main)"
  else
    BASE="HEAD~1"
  fi
fi

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  banner
  fail_line "unknown base ref: $BASE"
  exit 1
fi

CHANGED=()
while IFS= read -r line; do
  CHANGED+=("$line")
done < <(git diff --name-only --diff-filter=ACMR "$BASE" | grep -E '^src/.*\.(zig|js|mjs|html|java)$|^build\.zig$' || true)

banner
printf '%b base %s — %d changed file(s)\n' "${C_DIM}" "${BASE:0:12}" "${#CHANGED[@]}"

if [[ ${#CHANGED[@]} -eq 0 ]]; then
  pass_line "no changed source files to scan"
  exit 0
fi

FAIL=0
VIOLATIONS=()
VIOLATION_SAMPLES=()

note_violation() {
  local msg=$1
  local samples=${2:-}
  VIOLATIONS+=("$msg")
  VIOLATION_SAMPLES+=("$samples")
  FAIL=1
}

# --- helpers: scan only added/changed lines in the diff ---
# Each file is diffed once; every check reads the cached diff instead of running git again.
DIFF_DIR="$(mktemp -d)"
trap 'rm -rf "$DIFF_DIR"' EXIT
for f in "${CHANGED[@]}"; do
  key="$DIFF_DIR/${f//\//__}"
  git diff -U0 "$BASE" -- "$f" > "$key.diff"
  sed -n 's/^+//p' "$key.diff" | grep -v '^+++' > "$key.added" || true
done

file_diff() {
  cat "$DIFF_DIR/${1//\//__}.diff"
}

diff_added_lines() {
  cat "$DIFF_DIR/${1//\//__}.added"
}

check_added_pattern() {
  local file=$1 pattern=$2 msg=$3
  local hits
  hits="$(grep -E "$pattern" "$DIFF_DIR/${file//\//__}.added" | grep -vE '^\s*test "' || true)"
  if [[ -n "$hits" ]]; then
    note_violation "$msg in ${file}" "$(echo "$hits" | head -3 | sed 's/^/+ /')"
  fi
}

added_public_symbol_lines() {
  local file=$1
  file_diff "$file" | awk '
    /^@@/ {
      if (match($0, /\+[0-9]+/)) {
        line = substr($0, RSTART + 1, RLENGTH - 1) - 1
      }
      next
    }
    /^\+\+\+/ { next }
    /^\+/ {
      line++
      txt = substr($0, 2)
      if (txt ~ /^[[:space:]]*pub[[:space:]]+fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ ||
          txt ~ /^[[:space:]]*pub[[:space:]]+const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(struct|enum|union|opaque)\b/ ||
          txt ~ /^[[:space:]]*pub[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/) {
        print line ":" txt
      }
      next
    }
    /^-/ { next }
    { line++ }
  ' || true
}

has_doc_comment_above() {
  local file=$1 line=$2
  local n=$((line - 1))
  while [[ $n -ge 1 ]]; do
    local prev
    prev="$(awk -v n="$n" 'NR==n { print; exit }' "$file")"
    local trimmed="${prev#"${prev%%[![:space:]]*}"}"
    if [[ -z "$trimmed" ]]; then
      n=$((n - 1))
      continue
    fi
    [[ "$trimmed" =~ ^// ]] && return 0
    return 1
  done
  return 1
}

# --- 1. Code comments: no issue/session citations (AGENTS.md) ---
ISSUE_PAT='(\(#[0-9]+\)|#[0-9]{2,}|Issue [0-9]+|issue [0-9]+|spec: issue-[0-9]+|[Ss]tep [0-9]+|[Cc]hunk [0-9]+)'

for f in "${CHANGED[@]}"; do
  [[ "$f" =~ \.(zig|js|mjs|html)$ ]] || continue
  check_added_pattern "$f" "$ISSUE_PAT" "issue/session reference in code comment"
done

# --- 2. Wasm JSON boundary: escape user/engine strings (ADR-0010 wire) ---
for f in "${CHANGED[@]}"; do
  [[ "$f" == *boundary.zig ]] || continue
  check_added_pattern "$f" '"\{s\}".*(error|msg|Message)' \
    "unescaped JSON string interpolation (use encodeJsonString)"
  check_added_pattern "$f" '\{\{"ok":false,"error":"\{s\}"\}\}' \
    "unescaped JSON error shape (use encodeJsonString)"
done

# --- 3. Architecture: io-free GameEngine (CONTEXT.md) ---
for f in "${CHANGED[@]}"; do
  [[ "$f" == *game_engine.zig ]] || continue
  check_added_pattern "$f" 'FileTransport|saveGame|openGame' \
    "file I/O seam reintroduced into GameEngine"
  check_added_pattern "$f" '(data_dir|last_save_msg):' \
    "native session fields in GameEngine (belong in native shell)"
done

# --- 4. Architecture: wasm shell owns files, not parallel browser storage ---
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ src/wasm/.*\.(js|mjs)$ ]] || continue
  check_added_pattern "$f" 'localStorage' \
    "localStorage in wasm shell (view prefs belong in engine Config)"
done

# --- 5. Retired symbols should not reappear in src ---
RETIRED_PAT='BootstrapConfig|WasmHost|WasmTransport|WasmRenderer'
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/ ]] || continue
  check_added_pattern "$f" "$RETIRED_PAT" "retired architecture symbol reintroduced"
done

# --- 6. DRY: one route→asset map on Router (web_host) ---
for f in "${CHANGED[@]}"; do
  [[ "$f" == src/web_host/* ]] || continue
  check_added_pattern "$f" 'fn assetBody' \
    "parallel assetBody helper (use Router.body/contentType)"
  if [[ -f "$f" ]] && grep -q '^fn serveClient' "$f"; then
    serve_body="$(awk '/^fn serveClient\(/,/^fn [a-zA-Z_]/ { if (/^fn [a-zA-Z_]/ && !/^fn serveClient/) exit; print }' "$f")"
    if echo "$serve_body" | grep -qE 'embed\.(page_html|glue_js)|wasm_bytes\.'; then
      note_violation "inline route asset switch in serveClient ${f} (use Router.body/contentType)" \
        "$(echo "$serve_body" | grep -E 'embed\.(page_html|glue_js)|wasm_bytes\.' | head -2 | sed 's/^/  /')"
    fi
  fi
done

# --- 7. DRY: duplicate wasm cell wire structs ---
for f in "${CHANGED[@]}"; do
  [[ "$f" == *wire.zig ]] || continue
  if grep -q 'const JsonCell' "$f" && grep -q 'const CellSnapshot' "$f"; then
    note_violation "duplicate cell wire structs in ${f} (share CellSnapshot)" ""
  fi
done

# --- 8. SOLID / test hygiene: no live browser spawn in unit tests ---
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ \.zig$ ]] || continue
  added="$(diff_added_lines "$f")"
  if echo "$added" | grep -qE 'test .*openBrowser\(std\.testing'; then
    if ! echo "$added" | grep -q 'openBrowserWith'; then
      note_violation "live browser spawn in test ${f} (use openBrowserWith + recording spawn)" ""
    fi
  fi
done

# --- 9. Public Zig API docs are mandatory (AGENTS.md "Coding standards") ---
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ \.zig$ ]] || continue
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    line_no="${rec%%:*}"
    sym="${rec#*:}"
    if ! has_doc_comment_above "$f" "$line_no"; then
      note_violation "undocumented public Zig symbol in ${f}:${line_no}" "+ ${sym}"
    fi
  done < <(added_public_symbol_lines "$f")
done

# --- 10. Ownership gate: keep wasm adapters policy-thin ---
# Block host write-policy/state-machine leakage into new wasm modules.
WASM_POLICY_PAT='(write_context|startup_(restore|new|idle)|auto_save_success|new_game_success|import_success|paste_success|/current-file-context|X-Sudoku-Replace|replace_required)'
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/wasm/.*\.(js|mjs|html)$ ]] || continue
  check_added_pattern "$f" "$WASM_POLICY_PAT" \
    "wasm policy leak (keep web adapter transport-thin; policy belongs to file_policy/web_host seam)"
done

# --- 11. Policy authority gate: transition literals defined once ---
WRITE_EVENT_LITS='("startup_restore"|"startup_new"|"startup_idle"|"open_success"|"save_success"|"save_as_success"|"auto_save_success"|"new_game_success"|"import_success"|"paste_success")'
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/.*\.(zig|js|mjs|html)$ ]] || continue
  # Single source of truth in file_policy.
  case "$f" in
    src/core/file_policy.zig) continue ;;
  esac
  check_added_pattern "$f" "$WRITE_EVENT_LITS" \
    "duplicated write-context event literals (define in file_policy; avoid cross-layer copies)"
done

# --- 12. DRY: no local write-context event map fixtures in wasm tests ---
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/wasm/.*\.mjs$ ]] || continue
  check_added_pattern "$f" 'const[[:space:]]+WRITE_CONTEXT_EVENTS[[:space:]]*=[[:space:]]*\{' \
    "local write-context event map fixture (write-context events are core-owned; take them from core)"
done

# --- 13. Text ownership: adapters show core's sentences; they do not write their own ---
# Dialog and status text is always full sentences, so a sentence-shaped literal in adapter code is
# text the adapter wrote. Comments, log calls, tests and Zig `test` blocks are not user text.
ADAPTER_TEXT_PAT="[\"'\`][A-Z][^\"'\`]* [^\"'\`]*[.!?][\"'\`]"
ADAPTER_TEXT_COMMENT='^[0-9]+:[[:space:]]*(//|\*|/\*|#|<!--)'
ADAPTER_TEXT_LOG='\blog\.(debug|info|warn|err|fatal)\(|Log\.[dewiv]\(|clientLog\(|console\.(log|warn|error)\(|std\.debug\.print\('
# Platform-only text, for behaviour no core flow implements: "<file>" when the whole file is such
# text, "<file> <CONSTANT>" for one constant. Documented in docs/agents/verify-standards.md.
ADAPTER_TEXT_ALLOWED=(
  "src/wasm/artifacts/page.html BOOT_FAILED_MSG"
  "src/android/bootstrap/MainActivity.java BOOT_FAILED_MSG"
  "src/native/ascii/parser.zig"
  "src/native/ascii/renderer.zig NO_COMMANDS_MSG"
)

is_adapter_file() {
  [[ "$1" =~ ^src/(wasm|android|native|web_host)/.*\.(js|html|java|zig)$ || "$1" =~ ^src/entry_.*\.zig$ ]] || return 1
  [[ "$1" =~ ^src/android/test/ ]] && return 1
  return 0
}

# Added lines as "<line>:<text>", leaving out lines inside Zig `test` blocks.
added_lines_outside_tests() {
  local file=$1 test_lines=""
  if [[ "$file" =~ \.zig$ && -f "$file" ]]; then
    test_lines="$(awk '/^test "|^test \{/ { t = 1 } t { print NR } t && /^\}/ { t = 0 }' "$file" | tr '\n' ' ')"
  fi
  file_diff "$file" | awk -v skip="$test_lines" '
    BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) intest[s[i]] = 1 }
    /^@@/ { if (match($0, /\+[0-9]+/)) line = substr($0, RSTART + 1, RLENGTH - 1) - 1; next }
    /^\+\+\+/ { next }
    /^\+/ { line++; if (!(line in intest)) print line ":" substr($0, 2); next }
    /^-/ { next }
    { line++ }
  '
}

for entry in "${ADAPTER_TEXT_ALLOWED[@]}"; do
  read -r allowed_file allowed_const <<< "$entry"
  if [[ ! -f "$allowed_file" ]] || { [[ -n "$allowed_const" ]] && ! grep -qE "\b${allowed_const}\b[^=]*=" "$allowed_file"; }; then
    note_violation "stale adapter text allow-list entry: ${entry}" ""
  fi
done

for f in "${CHANGED[@]}"; do
  is_adapter_file "$f" || continue
  allowed_consts=()
  whole_file=0
  for entry in "${ADAPTER_TEXT_ALLOWED[@]}"; do
    read -r allowed_file allowed_const <<< "$entry"
    [[ "$allowed_file" == "$f" ]] || continue
    if [[ -z "$allowed_const" ]]; then whole_file=1; else allowed_consts+=("$allowed_const"); fi
  done
  [[ $whole_file -eq 1 ]] && continue
  if [[ "$f" =~ ^src/wasm/.*\.js$ && "$f" != src/wasm/artifacts/* ]]; then
    check_added_pattern "$f" 'msg[[:space:]]*:[^,]*\?\?[[:space:]]*["'\'']' \
      "adapter-written status fallback literal in a web module (status text belongs to core)"
  fi
  if [[ "$f" =~ ^src/native/shell/.*\.zig$ && "$f" != "src/native/shell/shell.zig" ]]; then
    check_added_pattern "$f" '\.msg[[:space:]]*=[[:space:]]*["'\'']' \
      "native shell adapter wrote a .msg literal (status text belongs to core)"
  fi
  hits="$(added_lines_outside_tests "$f" | grep -E "$ADAPTER_TEXT_PAT" | grep -vE "$ADAPTER_TEXT_COMMENT" | grep -vE "$ADAPTER_TEXT_LOG" || true)"
  for c in "${allowed_consts[@]+"${allowed_consts[@]}"}"; do
    hits="$(echo "$hits" | grep -vE "^[0-9]+:.*\b${c}\b[^=]*=" || true)"
  done
  if [[ -n "$hits" ]]; then
    note_violation "adapter-written dialog or status text in ${f} (show core's text; platform-only text goes on the allow-list)" \
      "$(echo "$hits" | head -3 | sed 's/^/+ /')"
  fi
done

# --- 14. Startup restore policy: do not route restore through named open copy ---
for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/wasm/(.*/)?startup\.js$ ]] || continue
  check_added_pattern "$f" 'name:[[:space:]]*restorePath' \
    "startup restore routed via open(name=restorePath) copy (use restore lane for persisted status)"
done

# --- 15. Core placement invariant: no JS/HTML under src/core ---
# Shared core owns portable policy/domain seams; adapter scripting belongs in
# frontend/platform layers.
while IFS= read -r core_asset; do
  [[ -z "$core_asset" ]] && continue
  [[ -f "$core_asset" ]] || continue
  note_violation "core placement violation: non-Zig source under src/core (${core_asset})" ""
done < <(git ls-files 'src/core/**/*.js' 'src/core/**/*.mjs' 'src/core/**/*.html')

# --- 16. Nothing is silent: every caught error in app code is logged with its system message ---
# A catch that cannot name the error, or that swaps it for a value without a log line, loses it.
# `catch unreachable` (an assertion) and `catch return Error.X` (propagation) are not flagged.
SILENT_CATCH_ZIG='catch[[:space:]]*\{[[:space:]]*\}|catch[[:space:]]*\|_\||catch[[:space:]]+(null|false|true|[0-9]+|"[^"]*"|\.\{\}|\.[A-Za-z_]+|continue|break|return([[:space:]]+(null|false|true|\.[A-Za-z_{][^;]*))?)[[:space:]]*[;,)]'
SILENT_CATCH_JS='catch[[:space:]]*\{|catch[[:space:]]*\([[:space:]]*_[A-Za-z0-9_]*[[:space:]]*\)|\.catch\([[:space:]]*\([[:space:]]*\)[[:space:]]*=>|catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}'
SILENT_CATCH_JAVA='catch[[:space:]]*\([^)]*[[:space:]](ignored|_)\)|catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}'

for f in "${CHANGED[@]}"; do
  [[ "$f" =~ ^src/test/ || "$f" =~ ^src/android/test/ || "$f" =~ \.test\.mjs$ || "$f" == src/wasm/test_support.mjs ]] && continue
  case "$f" in
    *.zig) pat="$SILENT_CATCH_ZIG" ;;
    src/wasm/*.js | src/wasm/*.html) pat="$SILENT_CATCH_JS" ;;
    src/android/*.java) pat="$SILENT_CATCH_JAVA" ;;
    *) continue ;;
  esac
  hits="$(added_lines_outside_tests "$f" | grep -E "$pat" | grep -vE "$ADAPTER_TEXT_COMMENT" || true)"
  if [[ -n "$hits" ]]; then
    note_violation "silent catch in ${f} (log the error with its system message; an expected one at info as \"expected: …\")" \
      "$(echo "$hits" | head -3 | sed 's/^/+ /')"
  fi
done

# --- report ---
if [[ $FAIL -eq 0 ]]; then
  pass_line "mechanical standards clean (${#CHANGED[@]} file(s))"
  printf '%b checks: issue refs, JSON escape, engine seams, wasm storage, retired symbols, serve/wire DRY, test side effects, public API docs, wasm ownership, policy authority, write-event fixture DRY, adapter text ownership, restore lane, core placement, silent catches\n' "${C_DIM}"
  printf '%b judgement calls (SOLID/spec) still need two-axis review\n' "${C_DIM}"
  exit 0
fi

fail_line "${#VIOLATIONS[@]} violation(s) on branch diff"
for i in "${!VIOLATIONS[@]}"; do
  printf '%b  • %s\n' "${C_RED}" "${VIOLATIONS[$i]}" >&2
  if [[ -n "${VIOLATION_SAMPLES[$i]:-}" ]]; then
    printf '%b%s\n' "${C_DIM}" "${VIOLATION_SAMPLES[$i]}" >&2
  fi
done
printf '%bsee docs/agents/verify-standards.md — fix or update the gate if a rule is wrong\n' "${C_YELLOW}" >&2
exit 1
