# Session State — Issue 02

Date: after T2 exec() implementation

## What's Done
- [x] T1: `parse()` refactored to thin dispatch, three module-level handlers (parseQuit, parseFill, parseClear)
- [x] T1: All 53 tests passing, coverage clean
- [x] T2: Added `CommandResult = union(enum){ ok, error_msg: []const u8 }`
- [x] T2: Added `exec(Command) !CommandResult` with tryFill/tryClear helpers
- [x] T2: Given-cell rejections surfaced as `.error_msg` instead of silently swallowed via catch
- [x] T2: Made FillData and ClearData public in command.zig for test access
- [x] All 57 tests passing (4 new T2 tests), game_engine coverage 95.65%

## What's Next
- **T3**: NEW `src/validator.zig` — walk Board views and flag conflicting cells
  - Write tests for empty board, row/col/box conflict detection, no false positives
  - Implement flagConflicts(board), add conflict_bits field to Board

## Architectural Notes
- Zig 0.17 doesn't support nested functions — handlers must be module-level with explicit params
- parse() feeds plain string tokens to helpers (not the tokenizer itself)
- Pattern: `if (verb == "X") { fetch args; return parseX(args); }`
- exec routes fill/clear/quit through tryFill/tryClear helpers after switching on command tag

## File State
- `src/command.zig`: FillData/ClearData now public for cross-module test access
- `src/game_engine.zig`: Added CommandResult type, exec(), tryFill(), tryClear() + 4 T2 tests
