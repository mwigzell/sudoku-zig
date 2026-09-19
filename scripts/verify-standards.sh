#!/usr/bin/env bash
# Mechanical standards gate for changed source — encodes AGENTS.md, CONTEXT.md,
# and .coding-standards.md rules that grep can enforce (DRY/architecture/SOLID
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
done < <(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD | grep -E '^src/.*\.(zig|js|mjs|html)$|^build\.zig$' || true)

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
diff_added_lines() {
  local file=$1
  git diff -U0 "$BASE"...HEAD -- "$file" | sed -n 's/^+//p' | grep -v '^+++' || true
}

check_added_pattern() {
  local file=$1 pattern=$2 msg=$3
  local hits
  hits="$(diff_added_lines "$file" | grep -E "$pattern" | grep -vE '^\s*test "' || true)"
  if [[ -n "$hits" ]]; then
    note_violation "$msg in ${file}" "$(echo "$hits" | head -3 | sed 's/^/+ /')"
  fi
}

# --- 1. Code comments: no issue/session citations (AGENTS.md) ---
ISSUE_PAT='(\(#[0-9]+\)|Issue [0-9]+|issue [0-9]+|spec: issue-[0-9]+|Step [0-9]+|chunk [0-9]+)'

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

# --- 6. DRY: one route→asset map on Router (serve.zig) ---
for f in "${CHANGED[@]}"; do
  [[ "$f" == *serve.zig ]] || continue
  check_added_pattern "$f" 'fn assetBody' \
    "parallel assetBody helper (use Router.body/contentType)"
  added="$(diff_added_lines "$f")"
  if echo "$added" | grep -q 'fn serveClient'; then
    if echo "$added" | grep -qE 'wasm_bytes\.(page_html|glue_js)'; then
      note_violation "inline route asset switch in serveClient ${f} (use Router.body/contentType)" \
        "$(echo "$added" | grep -E 'wasm_bytes\.(page_html|glue_js)' | head -2 | sed 's/^/+ /')"
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

# --- report ---
if [[ $FAIL -eq 0 ]]; then
  pass_line "mechanical standards clean (${#CHANGED[@]} file(s))"
  printf '%b checks: issue refs, JSON escape, engine seams, wasm storage, retired symbols, serve/wire DRY, test side effects\n' "${C_DIM}"
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
