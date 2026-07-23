Status: ready-for-agent

## Parent
`.scratch/sudoku/prd.md` (Interactive Play — command UX improvement)

## What to build

Replace the current exact-match command parser with **prefix-disambiguation**: the user types a prefix that uniquely identifies their intent, and the system resolves it. The legend is not static — it's computed each cycle from whatever commands are available in the current game state, so the parenthesized prefix position shifts as commands enter or leave.

**The key insight:** the parenthesis slides dynamically. With only five active commands `Fill`, `Clear`, `Undo`, `Redo`, `Quit` you get `(F)ill (C)lear (U)ndo (R)edo (Q)uit` — every prefix is one character. But imagine two commands collide on first letter (like a future `Recents` or `Reload`) — now "Redo" slides from `(R)edo` to `(RE)do` or further since they differ at position 2 (`d` vs…).

**Example:** if the command set were `Fill`, `Clear`, `Undo`, `Redo`, `Recents`, `Save`, `SaveAs`, the legend would show `(F)ill`, `(C)lear`, `(U)ndo`, `(RE)do`, `(REC)ents`, `(S)ave`, `(SA)veAs` — each parenthesized prefix is the minimum number of characters needed to distinguish that command from all others in the current set. Case-insensitive throughout.

- **Save/SaveAs:** real commands added in issue #25. Included as test data here to exercise hump-seed prefix collisions before the save/load wiring hits GameEngine's command list. Hump-seed technique (extract capital-letter skeleton for disambiguation) prevents ugly deep-prefix overlaps that pure pairwise would produce.

Core mechanics:
- **Line-based input stays** — user finishes typing before parsing happens (no per-character feedback).
- **Legend prints each cycle** alongside the board render, showing only commands valid in the current game state.
- **Case-insensitive** throughout.
- **Context-aware availability** — e.g., "Undo" is hidden when history is empty; "Redo" is hidden when no undone moves exist. This keeps the legend short and relevant.

Architectural note: keeping prefix-resolved dispatch as the only path — not argument-based inference (e.g., inferring "clear" from a lone coordinate), which would be brittle against future commands like Alternatives/Hint that also take coordinates.

---

## Context

- The existing parser in `src/command.zig` uses exact-match (`std.ascii.eqlIgnoreCase`) on the first token, plus single-letter shortcuts for `U`/`R`. It works but requires the user to know or guess valid prefixes.
- GameEngine already tracks undo/redo pointer state — we can query this to decide whether Undo/Redo should appear in the legend.
- The main loop in `src/sudoku.zig` (`run()`) reads a line via `std.io.getStdIn().reader()` and passes it to `parse()` → `exec()`. We'll keep that shape; only the parsing logic changes and we add a legend-print step.

---

## Steps (vertical slice)

### Step 1: Implement the prefix-disambiguation algorithm

**File:** `src/disambiguate.zig` (new module)

- Commands are stored and displayed in their canonical properly-capitalized form: `Fill`, `Clear`, `Undo`, `Redo`, `Quit`, `Save`, `SaveAs`.
- Define `pub fn getMinimumPrefixes(commands: []const []const u8) DisambiguationResult` that computes, for each command string, the minimum unique prefix length.
- Algorithm — case-insensitive pairwise: for each pair `(a, b)`, compute the position at which they first differ (if one is a proper prefix of the other, the shorter needs its full length + 1 as fallback). The minimum unique prefix for command `i` is the maximum over all `j != i` of this clash position.
- **Hump-seed disambiguation:** when pure pairwise would produce ugly deep-prefix results (e.g. `Save` vs `SaveAs`), extract each command's capital-letter skeleton (`Save` → `S`, `SaveAs` → `SA`) and run first-differ on that reduced form instead, then map back to get natural boundaries — `(S)ave` + `(SA)veAs`.
- Return struct that maps each original command to a prefix length `usize`.

### Step 2: Tests for disambiguation algorithm

**File:** `src/disambiguate.zig` (co-located test block)

- Test with the live command set: `{"Fill", "Clear", "Undo", "Redo", "Quit"}` — verify each prefix is 1 char.
- Test hump-seed collision: `{"Save", "SaveAs"}` — Save → 1 char (`S`), SaveAs → 2 chars (`SA`).
- Test single-command list returns length-1 prefix.
- Test case-insensitivity in inputs.
- Test empty list returns empty result.

### Step 3: Add context-aware command availability to GameEngine

**File:** `src/game_engine.zig`

- New method `pub fn getAvailableCommands(self: *const GameEngine) void` — or similar — that returns a slice/list of currently-available command names in their canonical form (e.g. `"Fill"`, `"Clear"`).
- Logic: always include `"Fill"`, `"Clear"`, `"Quit"`. Include `"Undo"` only if history pointer > 0. Include `"Redo"` only if pointer + 1 < history length.
- This is a read-only query; does not mutate state.

### Step 4: Rewrite the parser to use prefix dispatch

**File:** `src/command.zig`

- Accept a list of available command names (from Step 3).
- Tokenize input as before, take the verb (first word), and look it up via the disambiguation algorithm.
- If the verb matches exactly one command's minimum prefix → dispatch to that verb's argument parser as today.
- If the verb is ambiguous (matches more than one command at the typed length) → return `.error_msg` listing which commands were matched.
- Remove the special-case single-letter `U`/`R` shortcut code — the disambiguator produces these naturally (they'll be `(U)ndo`, `(R)edo`).
- If the verb doesn't match any command's prefix at all → `.error_msg("unknown command")`.

### Step 5: Implement the legend printer

**File:** `src/legend.zig` (new module) or co-located in `src/command.zig`

- Function `pub fn formatLegend(commands: []const DisambiguationEntry) []u8` that takes the disambiguation results and returns formatted strings like `(F)ill`, `(RE)do` — inserting parentheses around just the minimum distinguishing prefix for each command.

### Step 6: Wire into main loop — print legend each cycle

**File:** `src/sudoku.zig` (`run`)

- After rendering the board, print the legend line.
- Call `gameEngine.getAvailableCommands()`, run through disambiguator, pass to legend printer, output via existing writer infrastructure.

### Step 7: Integration tests — end-to-end prefix parsing through command→event seam

**File:** `src/command.zig` test block (co-located)

- Test that typing `"f A1 7"` resolves to Fill (user input case-insensitive).
- Test that typing `"q"` resolves to quit.
- Test that ambiguous input returns `.error_msg` (e.g., typing `"r"` when both redo and another `r...` command existed — though with current set it should resolve).
- Test case-insensitivity: `"F a1 3"`, `"Fi B2 5"`.

### Step 8: Update root.zig imports

**File:** `src/root.zig`

- Add import for new `disambiguate.zig` module (and `legend.zig` if separate).
- Reference in root test block so tests are discovered.

---

## Acceptance criteria

- [ ] Disambiguation algorithm correctly computes minimum unique prefixes for any command set
- [ ] Shared-prefix collision handled: `"Save"` vs `"SaveAs"` produces distinct minimal prefixes via hump-seed disambiguation
- [ ] GameEngine exposes `getAvailableCommands()` returning context-aware list (undo/redo hidden when not applicable)
- [ ] Parser resolves partial prefixes unambiguously and dispatches to correct argument parser
- [ ] Ambiguous input returns `.error_msg` with helpful description
- [ ] Legend prints each cycle showing available commands with parenthesized minimum unique prefix
- [ ] Legend's parenthesized prefix positions shift dynamically as commands enter/leave the available set (e.g., "redo" shows `(R)edo` when alone on `r`, but `(RE)do` or further when a new `r...` command joins)
- [ ] Case-insensitive throughout (typing, legend display)
- [ ] Single-letter shortcuts `U`/`R` still work (via disambiguation, not special-casing)
- [ ] Integration tests prove prefix dispatch through command→event seam
- [ ] Full test suite passes (`zig build test`)

## Blocked by
_(none)_
