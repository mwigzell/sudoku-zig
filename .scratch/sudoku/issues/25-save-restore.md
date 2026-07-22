Status: ready-for-agent

## Parent
`.scratch/sudoku/prd.md` (Out of Scope extension)

## What to build
In-game `SAVE <path>` and `LOAD <path>` commands that serialize the full game state (81-cell flat vector + entire `MutationHistory` stack + pointer index) to disk, and deserialize it back. Restoring a save continues exactly where you left off, with all prior undos/redos intact.

**Architectural note:** Because persistence is now in scope, the `Board` domain model must expose a clean serialization seam (`toFlat()`) so saving doesn't reach into internal arrays later.

---

## Context
- Saves are explicit file writes; no implicit autosaving or session-local persistence.
- Uses standard Zig `std.fs` I/O (no network/WASM dependencies). WASM browser renderer will need a separate JS-backed save path later if needed.
- The command structure (`Command`) already exists and needs two new variants plus a simple filename argument parser.

---

## Steps (vertical slice)

### Step 1: Define `SAVE` and `LOAD` commands
**File:** `src/command.zig`
- Add `.save = struct { path: []const u8 }` and `.load = struct { path: []const u8 }`.
- Extend the string parser in command.zig to recognize `"SAVE <path>"` and `"LOAD <path>"`, parsing out the filename argument.

### Step 2: Add Board serialization helper (`Board.toFlat()`)
**File:** `src/board.zig`
- Add `pub fn toFlat(self: Board) [81]u8` that walks `self.cells[]` and returns a raw `[81]u8` array. (We can also return/serialize `given_bits` or derive givens from the flat data, since non-zero values in the initial vector imply given-clues).
- This gives us a trivial memory dump of the current board state for saving without touching GameEngine internals later.

### Step 3: Decide on serialization format (binary is simplest)
**File:** `src/game_engine.zig` internal helper type for saving/loading protocol.
- File header/metadata (e.g., magic bytes or version, active_count: u8, pointer: u8). 
- Dump the history entries (row:u4, col:u4, old_value:u4) one after another based on active count).
- Finally write the 81 cell values.

### Step 4: Write `saveGame()` helper in GameEngine
**File:** `src/game_engine.zig`
- Implement `pub fn saveGame(path: []const u8) anyerror!void`. Open file using std.fs.File.writeAll/writeInt` helpers to dump state and history stack. If I/O error, fail gracefully.

### Step 5: Wire `.save in exec()
**File:** `src/game_engine.zig` (`exec`)
- Call `self.saveGame(cmd.save.path)`, return `Event.ok { .board_view = self.board.asView(), .msg = null }` on success. If file write fails, return `.error_msg("could not save").

### Step 6: Implement `loadGame(path)` helper
**File:** `src/game_engine.zig (exec)
- Read header/metadata, restore the 81-cell flat state via existing `fromFlat()`, and rebuild the `MutationHistory` array + pointer from disk. 
- Return `.error_msg("corrupt save") if file is bad or length mismatch).

### Step 7: Wire `.load in exec()
**File:** `src/game_engine.zig` (`exec`) - Call self.loadGame(cmd.load.path), return Event.ok { .board_view = self.board.asView(), .msg = null } on success (or .error_msg(...).

### Step 8: Integration tests through command->event seam
File: src/game_engine.zig test block (co-located)
- test "save/load round-trip preserves state" - fill a few cells, undo one, save to temp file, load it back. Assert board view matches exactly. No internal poking. 
- test "save/load round-trip preserves pointer position".

## Acceptance criteria

- [ ] Command.save and Command.load defined and parseable as SAVE /path/to/file" (case-insensitive)
- [ ] Board exposes a trivial toFlat() seam for dumping cell values + given mask to disk reliably.
- [ ] Loading restores state perfectly, including ability to undo/redo past actions.
- [ ] Integration tests exercise save/load through command->event seam only (no internal state poking).
- [ ] File errors gracefully return .error_msg so gameplay doesn't crash.

## Blocked by
_(none)_
