# Save File Binary Format Spec (v0.1)

## Layout

```
Offset 0        | Offset 11              | Offset 11+N×2                | End
┌───────────────┬──────────────────────┬───────────────────────────┐
│ Header(11B    │ History entries N×2   │ Trailer(97B)             │
│ +version ptr │ bytes each           │                          │
│ +entry_count  │                      │ given_bits(16) + flat_board(81)         │
└───────────────┴──────────────────────┴───────────────────────────┘

Total size: **108 + 2×N** bytes (where N = entry count).

---

## Structs

### `SaveFileHeader` — 11 bytes, packed

```zig
pub const SaveFileHeader = packed(align(1)) struct {    magic:        [4]u8,     // ASCII "SUD0"; validates file type.
    version_major: u8,       // 0 (bumps on format breakage).
    version_minor: u8,       // 0.
    version_patch: u8,       // 1 (bumps on additions/fixes).
    pointer:      u16,       // undo/redo index into history entries.
    entry_count:  u16,       // number of SaveEntry records that follow the header/trailer.};
```

Size: 4 + 3 + 2 + 2 = **11 bytes**.

### `SaveFileTrailer` — 97 bytes, packed

```zig
pub const SaveFileTrailer = packed(align(1)) struct {    given_bits: u128,       // givens bitmask (1 bit per cell; covers all 81 cells).
    flat_board: [CELL_COUNT]u8,     // 81-cell board values in row-major order.};
```

Size: 16 + 81 = **97 bytes**.

### `SaveEntry` — already exists, 2 bytes (unchanged):

## File Layout Table

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0      | 11   | `SaveFileHeader` | Magic + version + ptr + entry count |
| 11     | N×2  | `SaveEntry[N]`   | History entries in original order; replayed on load to restore MutationHistory (not through exec()) |
| 11+N×2 | 97   | `SaveFileTrailer` | given_bits + flat_board |

## Serialization Strategy (avoids `.interface` vtable small-write bug)

### Write (`GameEngine.saveGame(io, path: []const u8)`)

1. Open file → get buffered writer on stack handle (`std.Io`).
2. Compose header blob (magic + version + pointer + entry count).
3. **Write all:** `writeAll(std.mem.toBytes(&header))` — one blob call, 11 bytes.
4. Loop entries → `writeAll(std.mem.toBytes(&se))`. Each is one small write but these work correctly through the same writer context (not `.interface`).
5. Compose trailer from Board state (given_bits u128 + 81-byte flat board) as one blob → **97 bytes**.

### Read (`GameEngine.openGame(io, path: []const u8`)

1. Read first 11 bytes into header struct → validate magic + version ≥ **v0.0.1)**.
2. If `entry_count > 0:` read next `entry_count × 2` bytes into array → parse entries and replay history via `GameEngine.exec()` (undo/redo intact). Rebuild MutationHistory directly (don't go through exec()).
3. Read last 97 bytes → parse trailer → set `board.given_bits` + restore board via `Board.fromSaveState()`.

## Method Placement

| Method | On what? | Why? |
|--------|----------|------|
| `saveGame(io, path)` | **GameEngine** | Owner of header + history — orchestrates full file write. Board contributes its state only (trailer chunk). |
| `openGame(io, path)` | **GameEngine** | Reads header → replays history → loads trailer (board given_bits + flat cells) via `Board.fromSaveState()`. |
| `fromSaveState(SaveFileTrailer)` | **Board** | Clean deserialization seam — restores board from 97-byte trailer. Avoids touching GameEngine internals later. Returns error on mismatch. |

## Why Not `Board.toFlat()` and `BoardView`?

- `Board.toFlat()` exists but drops the givens mask (`given_bits` which isn't exported on BoardView).
- The new `fromSaveState()` adds that back — restores both cell values and the given bits.

