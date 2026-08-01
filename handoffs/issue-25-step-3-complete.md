# Handoff — Issue 25 Step 3: SaveFileHeader \& SaveFileTrailer Structs

## Status: ✅ Done (Step 3)

## What Was Built

### Structs (`src/game_engine.zig`)

**`SaveFileHeader`** (11B wire format):
- `magic: [4]u8` — "SUD0" identifier
- `version_major: u8`, `version_minor: u8`, `version_patch: u8` — versioning for format evolution
- `pointer: u16` — undo/redo history index
- `entry_count: u16` — number of SaveEntry records that follow

**`SaveFileTrailer`** (97B wire format):
- `given_bits: u128` — givens bitmask (covers all 81 cells)
- `flat_board: [81]u8` — board cell values in row-major order

### Wire Format Constants
- `SAVE_HEADER_SIZE = 11` bytes
- `SAVE_TRAILER_SIZE = 97` bytes

### Serialization Helpers (field-by-field to avoid struct padding)
- `writeSaveHeader(buf, header)` — writes 11 bytes in little-endian
- `readSaveHeader(buf)` — reads 11 bytes back into SaveFileHeader
- `writeSaveTrailer(buf, trailer)` — writes 97 bytes
- `readSaveTrailer(buf)` — reads 97 bytes back into SaveFileTrailer

## Tests Added (6 new, all passing)

| Test | What it proves |
|------|---------------|
| Wire format sizes (header=11, trailer=97) | Constants are correct per spec |
| Fields set/read back (header) | Struct fields work as expected |
| Fields set/read back (trailer) | Struct fields work as expected |
| Round-trip write/read header | Serialization is lossless for header |
| Round-trip write/read trailer | Serialization is lossless for trailer |

## Design Decision: Non-packed structs with field-by-field serialization

Zig doesn't allow arrays inside `packed struct`. Using regular structs means Zig adds alignment padding (header is 12B in memory, trailer is 112B), but the wire format constants and helper functions produce exactly 11B and 97B respectively. The round-trip tests prove byte-level fidelity.

## Next Steps

- **Step 4**: Implement `toSaveFormat(gpa)` on GameEngine using the helpers above
- **Step 5**: Implement `fromSaveFormat(gpa, buf)` for deserialization
- Pre-existing Step 6 round-trip file test still fails (`.interface` vtable byte-drift bug) — will be addressed in Steps 4-5 rewrite

## Test Results
- `zig test src/game_engine.zig --test-filter "SaveFile"` → **7/7 passed**
- `zig build test` → **161/162 passed** (1 pre-existing round-trip failure)
- `zig build run` → ✅ prints board + commands
