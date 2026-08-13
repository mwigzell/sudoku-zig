triage: needs-triage

## Implement the four New Game Options

The `newGameOptions` dialog currently returns a hardcoded `PuzzleGen.hard()` regardless of selection. All four branches need real implementations that source puzzle strings from their respective channels.

### Architecture

Each option must return an owned 81-char puzzle string via `_command.PuzzleResult.PuzzleString`. The stub at `newGameOptions` (ascii_renderer.zig) currently shows the menu, reads one line of input, and calls `PuzzleGen.hard()` unconditionally. The refactor is to dispatch on user choice and call the correct source function.

### Steps

#### Step 1: Implement "Generate New Puzzle"
- Sub-menu showing difficulty: Easy, Medium, Hard (numbered 1-3)
- Read sub-selection, call `PuzzleGen.generate(difficulty)` with the chosen difficulty
- Return owned puzzle string via `std.heap.page_allocator.dupe()`

#### Step 2: Implement "Open From File"
- Present a filename prompt (reuse existing `saveAsDialog` pattern for input)
- Read file contents using the same path resolution as `openGame`:
  - Relative paths → resolve through `path.resolveSavePath()` against data dir
  - Absolute paths → use directly
- Validate 81-char puzzle string format before returning (call `Board.fromFlat()` to check)
- Error on invalid / missing files

#### Step 3: Implement "Paste Puzzle String"
- Prompt user to paste an 81-character grid (empty lines/zeros or digits)
- Trim whitespace, validate length is exactly 81
- Validate via `Board.fromFlat()` before accepting
- Return owned puzzle string on success, error message on validation failure

#### Step 4: Implement "Load From URL" (deferred complexity)
- Prompt user for a URL (reuse readline pattern)
- Fetch puzzle string from HTTP endpoint
- This is the new surface — likely needs `std.http.client` or falls back to error explaining limitation in WASM sandbox
- **Acceptable initial implementation**: print "URL loading disabled" and return `.Cancelled` with a clear note, then follow-up issue for actual HTTP fetching

#### Step 5: Wire dispatch into `newGameOptions()`
- Replace hardcoded `PuzzleGen.hard()` with switch on user's numeric input (1-4)
- Input validation: reject out-of-range values with re-prompt or error
- Each branch calls its source function and returns the result

### Acceptance criteria
- [ ] Selecting "1" shows difficulty sub-menu and loads the chosen generated puzzle
- [ ] Selecting "2" prompts for filename, reads file, validates 81-char format, loads into game
- [ ] Selecting "3" accepts pasted 81-char string, validates, loads into game
- [ ] Selecting "4" either fetches or returns graceful error with message
- [ ] Out-of-range input (>4 or non-numeric) is handled gracefully (error or re-prompt)
- [ ] Each path through `.new` results in a playable board state
- [ ] All existing tests still pass (205+)
