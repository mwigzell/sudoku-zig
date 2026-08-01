Status: ready-for-agent

## Parent
`.scratch/sudoku/prd.md` (Out of Scope extension)

## What to build
In-game `SAVE <path>` and `OPEN <path>` commands that serialize the full game state (81-cell flat vector + entire `MutationHistory` stack + pointer index) to disk, and deserialize it back. Restoring a save continues exactly where you left off, with all prior undos/redos intact.

**Architectural note:** Because persistence is now in scope, the `Board` domain model must expose a clean serialization seam (`toFlat()`) so saving doesn't reach into internal arrays later.

---

## Context
- Saves are explicit file writes; no implicit autosaving or session-local persistence.
- Uses standard Zig I/O (no network/WASM dependencies). WASM browser renderer will need a separate JS-backed save path later if needed.
- The command structure (`Command`) already exists and needs `.save`/`.open` variants + simple filename argument parser.

---

### Save Signatures

| Method | Owner | Description |
| --- | --- | --- |
| `saveGame(io, path)` | **GameEngine** | Thin I/O wrapper — calls `toSaveFormat()`, writes result to disk via one `writeAll()` call. |
| `openGame(io, path)` | **GameEngine** | Reads whole file into buffer → passes to `fromSaveFormat(buf)`. Don't go through exec(). |
| `toSaveFormat(gpa: Allocator) []u8` | **GameEngine** | Serializes header + history entries + trailer (board state) into a heap-allocated byte array. Pure memory, no I/O. Enables easy testing and version migration. Returns error on allocation failure. Caller owns/freeing the buffer. |
| `fromSaveFormat(gpa: Allocator, buf: []const u8) GameEngine` | **GameEngine** | Deserializes a save buffer into a fresh GameEngine instance (with board + history). Validates magic/version before proceeding. Returns error on corrupt/unsupported data. |
| `fromSaveState(SaveFileTrailer)` | **Board** | Clean deserialization seam — restores board from trailer bytes. Avoids touching GameEngine internals later. Returns error on mismatch. |
| `equal(original: Board) bool` | **Board** | Compares two boards cell-by-cell plus given_bits. Needed for round-trip test assertions. |


---

## Binary Format Spec

### Layout

```
Offset 0        | Offset 11              | Offset 11+N×2                | End
┌───────────────┬──────────────────────┬───────────────────────────┐
│ Header(11B    │ History entries N×2   │ Trailer(97B)             │
│ +version ptr │ bytes each           │                          │
│ +entry_count  │                      │ given_bits(16) + flat_board(81) │
└───────────────┴──────────────────────┴───────────────────────────┘

Total size: **108 + 2×N** bytes (where N = entry count).
```

### `SaveFileHeader` — 11 bytes, packed

| Field | Type | Notes |
|-------|------|-------|
| magic | `[4]u8` | ASCII `"SUD0"`; validates file type |
| version_major | `u8` | 0 (bumps on format breakage) |
| version_minor | `u8` | 0 |
| version_patch | `u8` | 1 (bumps on additions/fixes) |
| pointer | `u16` | undo/redo index into history entries |
| entry_count | `u16` | number of SaveEntry records that follow |

### `SaveFileTrailer` — 97 bytes, packed

| Field | Type | Notes |
|-------|------|-------|
| given_bits | `u128` | givens bitmask (1 bit per cell; covers all 81 cells) |
| flat_board | `[81]u8` | board values in row-major order |

### `SaveEntry` — 2 bytes each

Already exists as `pub const SaveEntry = struct { coords: u8, values: u8 };`. Packed mutation entry: row+col in byte 0 (4 bits each), old_value+new_value in byte 1 (4 bits each from `CellValue(u4)`).

### Serialization Strategy

No sequential `.interface` small-write bug. Use `toSaveFormat()` → heap buffer → one call to `writeAll(buf)` writes everything atomically.

---

## Steps (vertical slice)

| Step | Status | Description |
|------|--------|-------------|
| 1 | ✅ Done | Define `SAVE` and `OPEN` commands in command.zig; parse `SAVE <path>` / `OPEN <path>`. **File:** `src/command.zig` — Add `.save = struct{ path: []const u8 }` and `.open = struct{ path: []const u8 }`. Extend the string parser (case-insensitive recognition). |
| 2 | ✅ Done | Add `Board.toFlat()` helper. **File:** `src/board.zig` — Returns `[81]u8` for cell values. Also export givens mask (`given_bits`). |
| 3 | ✅ Done | Define binary format structs: `SaveFileHeader` (11B wire) and `SaveFileTrailer` (97B wire). **File:** `src/game_engine.zig`. Added `writeSaveHeader`/`readSaveHeader` and `writeSaveTrailer`/`readSaveTrailer` helpers for field-by-field serialization. Non-packed structs with wire format constants to work around Zig packed-struct array limitation. |
| 4 | ⏳ Needs work | Implement `toSaveFormat(gpa)` on GameEngine — serializes header + history entries + trailer (board state) into heap-allocated byte array. **File:** `src/game_engine.zig`. Then rewrite `saveGame(io, path)` to call `toSaveFormat()` → one `writeAll(buf)` to disk. No `.interface` small-write bug. |
| 5 | ⏳ Needs work | Implement `fromSaveFormat(gpa, buf)` on GameEngine — deserializes a loaded buffer into fresh GameEngine instance (board + history intact in MutationHistory). **File:** `src/game_engine.zig`. Then rewrite `openGame(io, path)` to read whole file → pass buffer to `fromSaveFormat()`. |
| 6 | ✅ Done (moved) | Save is wired in **sudoku.zig** (not exec()) — `handleCommand().save` calls `self.engine.saveGame(io, ".sudoku_save.dat")`. exec() uses `else => @panic("save/open handled in sudoku.zig")` catch-all. This avoids `std.testing.io` in exec switch. |
| 7 | ❌ Not started | Wire `.open` in sudoku.zig — replace stub with `self.engine.openGame(io, o_data.path)`. **File:** `src/sudoku.zig`. Currently prints "open not yet implemented". Also add `Board.fromSaveState(SaveFileTrailer)` method for clean deserialization seam. |
| 8 | ⏳ Needs work | Add `Board.equal(other: Board) bool` comparison method — compares cells cell-by-cell plus given_bits mask. Needed by round-trip test assertions so we don't write manual loops everywhere. **File:** `src/board.zig`. |

---

## Acceptance Criteria

- [ ] Command.save and Command.open defined and parseable as `SAVE <path>` / `OPEN <path>` (case-insensitive)
- [ ] Board exposes a trivial toFlat() seam for dumping cell values + given mask to disk reliably
- [ ] Loading restores state perfectly, including ability to undo/redo past actions
- [ ] Integration tests exercise save/open through command→event seam only (no internal state poking)
- [ ] File errors gracefully return .error_msg so gameplay doesn't crash
