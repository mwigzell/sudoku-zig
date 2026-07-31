Status: in-progress

## Parent
`.scratch/sudoku/prd.md` (Out of Scope extension)

## What to build
In-game `SAVE <path>` and `OPEN <path>` commands that serialize the full game state (81-cell flat vector + entire `MutationHistory` stack + pointer index) to disk, and deserialize it back. Restoring a save continues exactly where you left off, with all prior undos/redos intact.

**Architectural note:** Because persistence is now in scope, the `Board` domain model must expose a clean serialization seam (`toFlat()` / `fromSaveState()`) so saving doesn't reach into internal arrays later.

---

## Context
- Saves are explicit file writes; no implicit autosaving or session-local persistence.
- Uses standard Zig I/O (no network/WASM dependencies). WASM browser renderer will need a separate JS-backed save path later if needed.
- The command structure (`Command`) already exists and needs `.save`/`.open` variants + simple filename argument parser.

---

## Steps (vertical slice)

| Step | Status | Description |
|------|--------|-------------|
| 1 | ✅ Done | Define `SAVE` and `OPEN` commands in command.zig; parse `SAVE <path>` / `OPEN <path>`. **File:** `src/command.zig` — Add `.save = struct{ path: []const u8 }` and `.open = struct{ path: []const u8 }`. Extend the string parser (case-insensitive recognition). |
| 2 | ✅ Done | Add `Board.toFlat()` helper. **File:** `src/board.zig` — Returns `[81]u8` for cell values. Also export givens mask (`given_bits`). |
| 3 | ⏳ In-progress | Define binary serialization format spec and implement structs. See `.scratch/sudoku/issues/25-save-restore/save-file-format.md`. Needs: `SaveFileHeader`, `SaveFileTrailer` packed). Reserved bytes in both structs for version stability (see below). All writes blob-level `writeAll(std.mem.toBytes(…))` — no sequential `.interface` small-write bug. The fix: use buffered writer's `writeAll` via I/O stack handle — one write per blob avoids vtable byte drift. |
| 4 | ⏳ Needs work | Rewrite `saveGame(io, path)` helper in GameEngine.**File:** `src/game_engine.zig` Open file using buffered writer (`std.Io`) to dump header → history entries → trailer (given_bits + flat board). If I/O error, fail gracefully. Current impl is broken due to `.interface` vtable bridge drops bytes past offset 8+. Needs rewrite. |
| 5 | ⏳ Blocked | Wire `.save > Build it (co-located) test "save/open round-trip preserves state" - fill a few cells, undo one, save to temp file, load it back. Assert board view matches exactly.)**File:** `src/game_engine.zig test block (co-located)**No internal poking.
- [ ] test "save/load round-trip preserves pointer position".

---

## Binary Format Spec

### Layout Summary: N × SaveEntry(2 bytes each) → [SaveFileTrailer (given_bits(u128) + flat_board([81]u8, packed — avoid padding that shifts field offsets on some platforms.

### `SaveEntry` — 2 bytes each (already exists as-is).

- No versioning or schema change tracking. Format is positional blob dump. Reserved bytes give us headroom to add fields later without shifting offsets. The file layout table (for reference only, no auto-gen):

| Offset | Size (bytes) | Field | Notes |
|--------|-------------|-------|-------|
| 0      | 8           | `SaveFileHeader` — packed struct; magic[4] + version_major(3) + pointer(u16) + entry_count(u16). No padding. |
| :+1:   | N×2         | `SaveEntry[N]` — history entries in order of occurrence. Replayed on load via GameEngine.exec()). |
| :+N:   | 97          | `SaveFileTrailer` — packed struct; given_bits(16B) + flat_board([81]u8 = 97 bytes total). |

→ **Total size:** 108 + 2×N bytes (where N = number of history entries.)

---

## Open Decisions / Notes
- `Board.fromSaveState(trailer: SaveFileTrailer)` — new method on Board to deserialize 9B trailer chunk. Avoids touching GameEngine internals later. |
| Method | Where? | Why? |
|--------|----------|------|
| `saveGame(io: std.Io, path: []const u8) anyerror!void` | **GameEngine**. Owner of header + history — orchestrates full file write. Board contributes only its state (trailer chunk). |
| `loadGame(io: std.Io, path: []const u8) anyerror!void` | **Board** — restore 9B trailer into board cells and given_bits. Returns error on mismatch with existing init pattern (`fromFlat` exists but BoardView drops givens mask. |

---

## What happened? Why the break?
- Original commit `fcd0a62` implemented saveGame via sequential `.interface` small writes → byte drift after offset 8+. That was never caught until the round-trip test was actually written (Issue 25 Step 8). The format spec in this issue doc says "hand-wavy description of fields." It should have been formalised BEFORE we started writing code. We didn't.

---

## Blocked by
- `.interface` byte drift bug — sequential small writes via vtable bridge lose sync past offset 8+. **Fix:** rewrite save/load to use buffered writer's `writeAll` via I/O stack handle — one write per blob avoids the bug (see Step 4 notes).
- exec() switch can't reference `std.testing.io` — .save/.open must be handled in sudoku.zig, not exec(). Current code uses else branch panic as workaround.
