# Handoff — Issue 25: Save/Open Serialization Decision & Status

## What We Discussed

**Key decision:** Move to **Option 2** — two-step serialization via `toSaveFormat()` / `fromSaveFormat()`. GameEngine serializes entire state (header + mutation history + board trailer) into a heap byte array first, then writes it out. This avoids the `.interface` vtable byte-drift bug from sequential small writes and makes round-trip testing trivial (serialize → deserialize in memory, no files needed).

## Where Things Stand

### Issue File ✅ Updated
Updated via targeted patches only:
- **Method Placement table** now lists `toSaveFormat(gpa)` ↔ `fromSaveFormat(gpa, buf)` as the core serialization pair. Thin I/O wrappers (`saveGame()`/`openGame()`) wrap those with single `writeAll()` calls.

### Code ⚠️ In Progress
- Added Step 3 structs to `game_engine.zig`. Need:
  - `SaveFileHeader` (packed 11B struct): magic[4] + version_major/patch + pointer(u16) + entry_count(u16)  
  - `SaveFileTrailer` (packed 97B struct): given_bits(u128) + flat_board([81]u8)
  
### Blocker: Edit Tool JSON Schema Issues
Every edit attempt to `game_engine.zig` fails with `"Edit request requires an 'edits' array"` despite correct JSON structure. This is happening on a file >10KB. The payloads are valid — something about the formatting or how the tool interprets them is wrong.

**Suggested workaround for next session:**
- Use `replace_text` instead when adding these structs (they have unique text in the file already — right after `SaveEntry` at line 26+).  
- If that fails: insert a marker comment first via tiny payload, then small edits around it.

## Suggested Skills
1. **handoff** (this doc is one) — save to disk when ready to end session
2. **codebase-design** — if refining the API shape further before implementation
3. **tdd** — once structs exist, TDD the `toSaveFormat()`/`fromSaveFormat()` round-trip

## Things NOT Changed (for reference)
- Original issue file's Steps 1→5 still reflect sequential writes; they need Step 4 → rewritten around `toSaveFormat()`. This is part of a larger restructure happening next cycle so hold off.
- `sudoku.zig` save wiring and `exec()` panic catch-all remain intact (correct per earlier decision).
