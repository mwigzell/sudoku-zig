Status: in-progress (T1 refactor ✔, ready for T2)

## Working mode

HITL. One TDD cycle per session.

## Parent

`.scratch/sudoku/prd.md` — US1, US2, US3: Interactive terminal Sudoku game with visible conflicts

---

## Preamble

Current `main()` bootstraps GameEngine and renders the initial board once, then exits. We are replacing that exit with a command-driven loop.

### Main loop anatomy

The loop is composed of named pieces that can be referenced independently in the test slices below:

| Piece | Role | Owner module |
|-------|------|-------------|
| **R — Render** | Full board redraw via `engine.render()` (renders BoardView through AsciiRenderer) | game_engine |
| **P — Prompt** | Print "> " to stdout so player knows input is expected | main |
| **L — Read line** | `readUntilDelimiterOrEof(buf, '\n')` from stdin; EOF breaks loop | main |
| **Pr — Parse** | Turn raw string into a `ParseCommandResult`; valid commands carry structure, invalid inputs carry a rejection message | command |
| **Sw — Switch on parse result** | Route: `.valid` → exec path, `.invalid_message` → acknowledge gate | main |
| **E — Exec** | Route Command through Board mutation + post-mutation validation; returns `CommandResult` (`.ok` loops immediately, `.error_msg` triggers acknowledge) | game_engine |
| **A — Acknowledge gate** | Print the error message and consume an empty Enter press before continuing loop; shared behaviour for both parse and exec errors | main |

```
while (true) {
    R  engine.render();                   // full board redraw, always first
    P  print("> ");                       // prompt player
    L  line = reader.readLine();           // stdin; EOF → break
    Pr result = parse(line);              // command.parser()
    Sw switch (result) {                  
        .valid => |cmd| {         
            try engine.exec(cmd);          // E — may return error_msg or ok
        },                                
        .invalid_message => |msg| {  
            waitAck(msg);                  // A — acknowledge gate
            continue;                      
        }                                 
    }                                    
}
```

### Method signatures

Reader can find the intended contract before implementation details:

```zig
// command.zig — T1, T6
pub const ParseCommandResult = union(enum) {
    valid: Command.Command,
    invalid_message: []const u8,
};

fn parse(input_line: []const u8) ParseCommandResult;

// game_engine.zig — T2, T4
pub const CommandResult = union(enum) {
    ok,
    error_msg: []const u8,
};

pub fn exec(self: *@This(), cmd: command.Command) anyerror!CommandResult;

// validator.zig — T3, called from T4
pub fn flagConflicts(board: *board.Board) void;

// main.zig — T6 (acknowledge gate, shared by both parse and exec errors)
fn waitAck(writer: anytype, msg: []const u8) anyerror!void;
```

### Two result types and the acknowledge gate

Both parse errors and execution rule violations travel through the same UI flow — print a message, wait for Enter, continue. Pure success (`.ok`) loops immediately without pausing.

| Source | Type | Variant values | Used by |
|--------|------|----------------|---------|
| **ParseCommandResult** | `union(enum)` | `.valid: Command` / `.invalid_message: []const u8` | main's Sw piece |
| **CommandResult** | `union(enum)` | `.ok` (loops tight) / `.error_msg: []const u8` (triggers A) | main's E piece → A piece |

This keeps parse-layer and exec-layer errors out of Zig's error union (`anyerror!`). The only `anyerror!` on the return path is a genuine runtime failure (IO error, OOM). User-facing failures are structured data.

### Command vocabulary

Three command variants — fill, clear, quit. Coordinate addressing is chess-style: A1 = column A row 1 (col 0, row 0), through I9. No separate `invalid` Command variant — bad input stays in the parser's error path and returns a rejection string via `ParseCommandResult.invalid_message`.

### Validator integration point

Validator runs post-mutation in the exec path. After Board mutation, walk all RowView, ColView, BoxView scopes and flag cells whose digit is duplicated within any scope of three. The per-cell conflict state lives on Board (set/clear) so it is captured in BoardView and flows through to Styler for decoration.

### Current state

- ✅ `Board` owns flat `[81]Cell`, can mutate cells via `setCell()`/`clearCell()`, has `isGiven()` guard
- ✅ `GameEngine(R)` wraps Board + Renderer — `fill()`, `render()`, `fillAndRender()`
- ✅ `AsciiRenderer(StylerType)` renders 9×9 grid with unicode borders, Styler seam for givens highlight
- ✅ `main()` bootstraps GameEngine and renders initial board once
- ❌ No stdin command parsing — game exits after initial render
- ❌ No Validator — conflicts between digits across row/col/box are not detected or marked
- ❌ `fill()` silently swallows given-cell rejections via `catch {}` — no feedback to player

---

### Test T1 — NEW `src/command.zig`: Command union + parser returning ParseCommandResult

**Verify before code:** Confirm no `src/command.zig` exists; confirm `game_engine.zig` has no `exec()` or `Command` import.

**Test (write first):**
- `"parse fill command A1 7 → .valid with row 0, col 0, digit seven"`
- `"parse clear command C3 → .valid clear at row 2 col 2"`
- `"parse quit → .valid quit"`
- `"parse empty line → .invalid_message"`
- `"parse unknown verb → .invalid_message describing the issue"`
- `"parse fill with out-of-range coordinates (J1) → .invalid_message"`
- `"parse fill A1 with non-digit value → .invalid_message"`

**Code (write after test):** New file `src/command.zig`:
- Define `pub const Command = union(enum) { fill, clear, quit };`
- Add data fields to variants: `fill` carries `{ row: u4, col: u4, digit: cell.CellValue }`; `clear` carries `{ row: u4, col: u4 }`
- Define `pub const ParseCommandResult = union(enum) { valid: Command, invalid_message: []const u8 };`
- Chess-style coordinate parser: column letter A–I → 0–8, row digit 1–9 → 0–8
- `fn parse(input_line: []const u8) ParseCommandResult` function
- Trim leading/trailing whitespace before parsing

**Verify after:** `zig test src/command.zig` passes all tests. No warnings.

---

### Test T2 — MOD `game_engine.zig`: exec(Command) returns CommandResult with given-cell feedback

**Verify before code:** Confirm current `fill()` method silently swallows `setCell` errors via `catch {}`. Note the absence of `CommandResult` type and any `exec()` method.

**Test (write first):**
- `"exec fill non-given cell → .ok"`  — uses MockRenderer, fills empty cell, asserts `.ok`
- `"exec fill given cell → .error_msg"` — attempts to overwrite a given, asserts error message contains "given" or similar explanation
- `"exec clear given cell → .error_msg"` — same guard for clear on locked cells
- `"exec quit → .ok"` (or dedicated signal) — quit is handled by main; exec should return without mutating state

**Code (write after test):** Modify `game_engine.zig`:
- Define `pub const CommandResult = union(enum) { ok, error_msg: []const u8 };`
- Import `command.Command`
- New `exec(cmd: Command) !CommandResult` method that switches on command variant
  - `.fill` → call `Board.setCell()` properly handling the `error.NotGiven` return and converting it to `.error_msg`, not swallowing it
  - `.clear` → call given-cell guard then `Board.clearCell()`. Note: current `clearCell()` is unconditional — add protection here in exec, or delegate to Board-level check
  - `.quit` → returns immediately without mutating state
- After mutation: call `engine.render()` so board reflects change before prompt

**Verify after:** `zig test src/game_engine.zig` passes. Existing tests still green. Confirm given-cell rejections are no longer silent.

---

### Test T3 — NEW `src/validator.zig`: walk Board views and flag conflicting cells

**Verify before code:** Confirm no validator module exists; confirm Board has no conflict-tracking field yet.

**Test (write first):**
- `"validate empty board → all clear"` — 81 cells, zero conflicts
- `"validate row conflict → both duplicate cells flagged"` — two cells in same row share digit, both marked
- `"validate column conflict → duplicates flagged"`
- `"validate box conflict → duplicates within 3×3 flagged"`
- `"validate no false positives — unique digits across all scopes"`

**Code (write after test):** New file `src/validator.zig`:
- Define result structure: per-board bitmask or `[81]bool` array of conflict flags
- Walk each RowView (9), ColView (9), BoxView (9)
- For each scope, scan 9 cells, detect any digit appearing more than once among non-empty cells
- Mark all conflicting positions (the cell and its peer(s))
- `pub fn flagConflicts(board: *Board) void` — modifies Board; always succeeds
- Board needs a new field for conflict state (e.g., `conflict_bits: u128`) — added to board.zig in this slice

**Verify after:** `zig test src/validator.zig` passes. Coverage on validator logic > 90%.

---

### Test T4 — MOD `game_engine.zig`: wire validator into exec path post-mutation

**Verify before code:** After T3 lands, confirm `flagConflicts()` exists and Board has conflict bits but they are not yet called from exec.

**Test (write first):**
- `"exec fill creates conflict → cell marked after render"` — fill a digit conflicting with existing row; MockRenderer snapshot should show conflict bit set on both cells
- `"exec clear resolves conflict → previously-conflicting peer now clean"` — remove one duplicate, the other is no longer flagged
- `"exec fill no conflict → no bits set"` — fill cell with unique digit

**Code (write after test):** Modify `game_engine.zig`:
- Import validator module
- In `exec()`: after the Board mutation (`setCell`/`clearCell`), call `validator.flagConflicts(&self.board)`
- This ensures conflict state is fresh before `render()` copies BoardView, so Styler can access it

**Verify after:** `zig test src/game_engine.zig` passes. Integration test chain: exec → mutation → validator → render → MockRenderer captures conflict marks.

---

### Test T5 — MOD `styler.zig`: AnsiStyler decorates conflicting cells

**Verify before code:** After T4, confirm BoardView exposes conflict info (new field or accessible via Board) but Styler only highlights givens with DIM_ON codes.

**Test (write first):**
- `"AnsiStyler: conflicting non-given cell gets distinct ANSI wrapping"` — format a row where one player-set cell is flagged; output should contain the conflict marker sequence, not just DIM_ON
- `"AnsiStyler: given cell takes precedence over conflict styling"`

**Code (write after test):** Modify `styler.zig`:
- Add ANSI escape constant for conflict decoration: `pub const CONFLICT_ON = "\x1b[7m"; // reverse-video`
- Update private `style_cell()` helper to accept a third bool parameter for conflict state
- In AnsiStyler, read conflict bits via BoardView and pass into `style_cell()`
- Prioritise given-style when cell is both given and flagged (given cells cannot be changed, so visual hierarchy: given → dim, player conflict → highlight)

**Verify after:** `zig test src/styler.zig` passes. `zig build run` shows initial board identical to pre-issue output (no new conflicts on a valid starting puzzle).

---

### Test T6 — MOD `main.zig`: full command loop with acknowledge gate

**Verify before code:** Current `main()` calls `engine.render()` once then returns. Preamble pieces P, L, Pr, Sw, A don't exist yet as code.

**Test (write first):** (T6 is too integration-heavy for inline test — verify via manual run instead)
- Verify-before: current binary renders and exits
- Plan manual verification steps below

**Code (write after test):** Rewrite `main.zig` to the loop anatomy from Preamble:
1. Initialise engine + renderer (unchanged)
2. Enter `while (true)` loop
3. **R** — `engine.render()`
4. **P** — `print("> ")`
5. **L** — `reader.readUntilDelimiterOrEof(buf, '\n')` — EOF or error → break
6. **Pr** — `result = command.parse(line)`
7. **Sw** — on `.valid`: route to exec; on `.invalid_message`: call `waitAck(msg); continue`
8. **E** — `execResult = try engine.exec(cmd)` switches:
   - `.quit` → break (exit program)
   - `.ok` → loop continues immediately
   - `.error_msg` → `waitAck(msg); continue`
9. Loop repeats from R
10. Define `fn waitAck(writer: anytype, msg: []const u8) anyerror!void`:
    - Write the error/warning message + newline to stdout via writer
    - Prompt with "> " (press Enter continues)
    - Read an empty line from stdin via `reader.readUntilDelimiterOrEof(buf, '\n')`
    - Loop continues after acknowledgement

**Verify after:**
- `zig build run` renders board, prompts "> "
- Type `fill A1 7` (empty cell) → cell updates on next render, loop continues
- Type `fill given_cell` → error message displayed, press Enter, prompt returns
- Type garbage → parse rejection displayed, press Enter, prompt returns
- Type `quit` → program exits cleanly
- `zig test src/root.zig` all prior tests still pass (T6 is main-level integration; its coverage comes through manual run)

---

## Acceptance criteria

- [ ] `Command` tagged union defined with fill/clear/quit variants and chess-style coordinate parse
- [ ] Parser returns `ParseCommandResult` — valid commands carry structure, invalid inputs carry rejection message
- [ ] GameEngine gains `exec(Command) !CommandResult` entry point; given-cell rejections surface as `.error_msg`, not silently swallowed
- [ ] Validator detects digit conflicts across row/col/box using Board RowView/ColView/BoxView topology
- [ ] Conflicting cells are visually distinguished in rendered output via AnsiStyler
- [ ] Main event loop runs: render → prompt → read → parse → switch → exec → (acknowledge gate on failures), tight loop on successes
- [ ] quit command exits cleanly
- [ ] Parse errors caught at stdin boundary and reported without crashing

## Blocked by

(none — Board, GameEngine, AsciiRenderer, Styler seam all delivered)

### Note on issue 05

Issue 05 (puzzle loading and difficulty levels) is a sibling concern, not a blocker. The command loop starts with a single embedded puzzle; once Command/Parser infrastructure exists, `new_puzzle <difficulty>` becomes a natural extension of that same layer.
