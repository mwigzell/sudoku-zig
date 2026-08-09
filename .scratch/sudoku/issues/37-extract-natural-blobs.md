triage: ready-for-agent

## Motivation

Two problems, one cause:

1. **large source files** — `board.zig` is ~1080 lines with 34 co-located tests. `game_engine.zig` has 50+ test blocks across its bottom half.
2. **test churn penalty** — every time you change one function, the whole test suite scrolls past everything else first. Finding your test block in a wall of 30 others is friction.

Zig makes module splits free: `pub fn` top-level + `@import` costs nothing. The seams are visible in test names.

## Board seams (from test prefixes)

### A. "Board: conflict bits…" and integration "validate / refreshConflictsForCell" (9 tests)

```
test "Board: conflict bits start clear and can be set/cleared individually"
test "Board: validate flags row duplicates"
test "Board: validate flags column duplicates"
test "Board: validate flags box-only conflicts"
test "Board: validate does not flag cells with no conflicts"
test "Board: validate flags cell when conflicting in multiple scopes"
test "Board: refreshConflictsForCell updates only affected scopes"
test "Board: refreshConflictsForCell creates new conflict"
test "Board: refreshConflictsForCell does not touch unrelated cells"
```

**Lines to extract:** `scopeToBoardMask()`,  `unitsMask()`,  `validate()`, `refreshConflictsForCell()` — lines ~248-340. Plus constants `DIMENSION_SIZE`, `BOX_DIMENSION`, `BoxCellCount`, conflict_bits semantics.

These call into the View constructors (`asRow`, `asCol`, `asBox`) and validator — but those live on Board and stay there, so the extracted module would just take a `*Board` pointer.

**Target file:** `board/conflict.zig`

### B. View-related tests (6 tests)

```
test "Board.BoardView.resolve() resolves same values as getCellValue"
test "Board: asRow produces contiguous indices for row n"
test "Board: asCol produces strided indices for column n"
test "Board: asBox(0, 1) produces correct scattered indices for top-middle box"
test "Board: BoardView reflects mutation on reborrow"
```

These exercise RowView/ColView/BoxView and asRow/asCol/asBox. Could group with the core board OR conflict module since Views are used by both. Probably best to leave on Board — they're part of its public API.

### C. Serialization tests (7 tests)

```
test "Board: constructs from flat puzzle array with correct values"
test "Board: fromOneLineString parses digits and dots correctly"
test "Board: fromFlat rejects out-of-range cell values"
test "Board: fromOneLineString rejects wrong length"
test "Board: fromOneLineString rejects invalid characters"
test "Board: fromFlat derives given bits dynamically per cell"
test "Board: toFlat produces [81]u8 matching current cell values"
test "Board: toFlat -> fromFlat round-trip preserves cell values"
```

**Lines:** `toFlat()`, `equal()`, `fromFlat()`, `fromOneLineString()`, `BoardError`, `FlatOpts` — lines ~204-394. These are standalone factory/serializer functions that return Board by value and never mutate it. Perfect extraction.

**Target file:** `board/board_serial.zig` (or just `board/serial.zig`)

### D. Core cell mutation tests (8 tests)

```
test "Board: init produces 81 empty cells and no givens"
test "Board: setCell places a digit on an empty cell"
test "Board: clearCell resets value and clears given bit"
test "Board: setCell errors when modifying a given cell"
test "Board: init sets all box digit bitmasks to zero"
test "Board: fromFlat initializes digit_bits for given cells"
test "Board: setCell updates box digit bitmask when changing a value"
test "Board: clearCell clears the digit bit from the owning box"
```

Stay on Board — they exercise the struct directly. This is the core surface.

### E. equal tests (3 tests)

```
test "Board: equal returns true for identical boards"
test "Board: equal returns false when cell values differ"
test "Board: equal returns false when given_bits differ"
```

`equal()` could go with serialization (section C) since it's a comparison utility.

---

## game_engine seams (from test names)

### F. Save wire format tests (~15 tests)

```
test "SaveEntry: total size is 2 bytes"
test "SaveEntry: pack and unpack coords (row col)"
test "SaveEntry: pack and unpack values (old_value new_value)"
test "SaveFileMagic is 4 bytes 'SUD0'"
test "Save file size: header + history_count(2) + N*entry_size + given_bits(16)"
test "saveGame returns error on bad path"
test "saveGame then openGame: full state round-trip equals original"
test "SaveFileHeader: wire format is 11 bytes"
test "SaveFileHeader: fields can be set and read back"
test "SaveFileHeader: round-trip write/read"
test "SaveFileTrailer: wire format is 97 bytes"
test "SaveFileTrailer: fields can be set and read back"
test "SaveFileTrailer: round-trip write/read"
test "toSaveFormat empty history produces buffer of correct size"
test "toSaveFormat header has correct magic and version"
test "toSaveFormat includes history entries and correct trailer"
test "fromSaveFormat round-trip: board state given_bits history"
```

These test `SaveEntry`, `SaveFileHeader`, `SaveFileTrailer`, `writeSaveHeader/Trailer`, `readSaveHeader/Trailer`, `saveGame()`, `toSaveFormat()`, `openGame()`, `fromSaveFormat()` — lines ~64-299. This is the serialization layer and doesn't need exec/dispatch logic or MutationHistory integration.

**Target file:** `engine/save_format.zig` (after #36 moves game_engine into engine/)

### G. GameEngine integration tests (~15 tests)

```
test "GameEngine fill updates cell value"
test "GameEngine init builds board from puzzle string"
test "exec fill non-given cell → .ok"
test "exec fill given cell → .error_msg"
test "exec clear given cell → .error_msg"
test "exec quit → .ok"
test "exec fill creates conflict → cell marked"
... (through) ...
test "exec open: delegates to open handler via command/open.zig"
```

These test exec(), availableCommands, tryFill — the controller layer. Stay on GameEngine. Smaller once save wires leave.

### H. MutationHistory tests (~4 tests)

Already partly covered by issue #36 (mutation_history moved to engine/). Their tests move with them naturally.

---

## The plan

### Step 1 — `board/serial.zig` ✅ DONE (b0d79be)

Extract from `board.zig`:
- Functions: `toFlat`, `equal`, `fromFlat`, `fromOneLineString`
- Types: `BoardError`, `FlatOpts`
- Tests: 10 blocks (sections C + E above)

Add re-export aliases in board.zig for backward compat so callers that do `board.fromFlat()` or `board.fromOneLineString()` still compile.

### Step 2 — `board/conflict.zig` ✅ DONE

Extract from `board.zig`:
- Functions: `scopeToBoardMask`, `unitsMask`, `validate`, `refreshConflictsForCell`
- Tests: 9 blocks (section F above)

Re-export in board.zig for backward compat (`pub const validate = conflict_module.validate;`). Callers that do `board.validate()` become `conflict.validate(&board)` — or keep the alias.

### Step 3 — `engine/save_format.zig` (depends on #36 landing first)

Extract from game_engine.zig:
- Types: `SaveFileMagic`, `SaveFileVersion`, `SaveFileHeader`, `SaveFileTrailer`, `SaveEntry`, constants `SAVE_HEADER_SIZE`, `SAVE_TRAILER_SIZE`
- Functions: `writeSaveHeader`, `readSaveHeader`, `writeSaveTrailer`, `readSaveTrailer`, `saveGame`, `toSaveFormat`, `openGame`, `fromSaveFormat`
- Tests: 17 blocks (section F above)

Import by both game_engine.zig (re-export for now) and the new save handler files.

## Acceptance criteria

- [x] `board/serial.zig` exists with 4 free fns + BoardError + FlatOpts + 10 tests ✅ b0d79be
- [x] `board/conflict.zig` exists with 4 free fns + 9 tests ✅
- [x] board.zig reduced from ~1080 lines to ~600 (core: struct + views + cell mutation + digit bits) ✅ 560 lines
- [ ] After #36: `engine/save_format.zig` exists with wire types + IO functions + 17 tests
- [ ] game_engine.zig reduced from ~400+ lines to ~250 (controller only)
- [ ] Backward-compat re-exports in board.zig and game_engine.zig so external callers don't break
- [x] `zig build test` passes all 217+ tests with no missing coverage ✅ 220/220
- [x] `zig build run` works end-to-end ✅
