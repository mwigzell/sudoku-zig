# Handoff — Issue 25 Step 4: toSaveFormat Implementation

## Status: ✅ Done (Step 4)

## What Was Built

### `GameEngine.toSaveFormat(gpa: std.mem.Allocator) ![]u8` (`src/game_engine.zig`)

Serializes complete game state (header + history entries + trailer) into a heap-allocated byte buffer. Caller owns the buffer and must free it with the same allocator.

**Algorithm:**
1. Calculate total size: `SAVE_HEADER_SIZE(11) + (entry_count × 2) + SAVE_TRAILER_SIZE(97)`
2. Allocate buffer via provided allocator
3. Write header (magic + version + pointer + entry_count) using `writeSaveHeader()`
4. Write each `MutationEntry` as a `SaveEntry` (coords byte, values byte)
5. Write trailer (given_bits + flat_board) using `writeSaveTrailer()`

### Rewritten `saveGame(io, path)` 

Replaced the old `.interface`-based sequential small-write implementation with the two-step blob approach:
1. Call `toSaveFormat(std.heap.page_allocator)` to get complete byte buffer
2. Write entire buffer atomically via `file.writeAll(io, buf)`
3. Free buffer on defer

This avoids the `.interface` vtable byte-drift bug that was causing the round-trip test to fail.

### Tests Added (3 new)

| Test | What it proves |
|------|---------------|
| Buffer size with empty history | Correct sizing: 108 bytes (header + trailer only) |
| Header content validation | Magic, version, pointer, entry_count all correct in serialized form |
| History entries and trailer round-trip | 3 mutations produce 114-byte buffer; first entry verifies; trailer flat_board has correct mutated values; given_bits preserved |

## Known Issues

### `zig build test` still fails (1 pre-existing crash)

The Step 6 round-trip file test still crashes because it uses the OLD wire format expectations — `saveGame()` now writes the NEW 11-byte header with pointer as u16 and entry_count as u16, but the old test was written against a different header layout (magic + version only). This is expected: Step 5 (`fromSaveFormat`) will replace that test anyway.

## Test Results

- `zig test src/game_engine.zig --test-filter "toSaveFormat"` → **3/3 passed**
- `zig build test` → **164/165 pass** (1 pre-existing round-trip failure)
- `zig build run` → ✅ prints board + commands

## Next Steps

- **Step 5**: Implement `fromSaveFormat(gpa, buf)` — deserialize buffer into fresh GameEngine instance. Will need to read header, reconstruct entries, restore trailer board state.
- The old Step 6 round-trip file test should be rewritten after Step 5 is complete, using in-memory buffers instead of files for testing.

## Design Notes

- Used `@memcpy` for the empty-history path but switched to direct byte assignment for SaveEntry writes — Zig was complaining about source/destination length mismatch with `std.mem.toBytes()` returning `[8]u8` when only 2 bytes were needed from a 2-byte struct, causing runtime panic.
- The old sequential write tests (Step 4 original) need to be updated once Step 5 is done, as they tested the OLD wire format expectations.
