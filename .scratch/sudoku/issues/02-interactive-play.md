Status: ready-for-agent

## Working mode
HITL. One TDD cycle per session.

## Parent
`.scratch/sudoku/prd.md` — US1: Interactive terminal Sudoku game

## What to build
A command-driven loop in `main()` that repeatedly prompts for input, reads stdin, parses a Command, sends it to GameEngine, and re-renders the board.

Current main bootstraps GameEngine and renders once — then exits. We need it to enter this loop instead:

```
1. engine.render()            // render BoardView via AsciiRenderer (already works)
2. prompt "> "
3. read line from stdin
4. parse(line) → Command
5. engine.exec(cmd)
   ├─ fill  → mutate cell + validate + re-render
   ├─ clear → clear cell + validate + re-render
   └─ quit  → return Quit signal, main breaks loop
```

`BoardView` (from `Board.asView()`) is the snapshot GameEngine passes to Renderer. No separate Event type — that was leftover terminology from an earlier design.

### Current state (as of 2026-07-18)
- ✅ `Board` owns Grid topology, can mutate cells via `setCell()`/`clearCell()`, has `isGiven()` guard
- ✅ `GameEngine(R)` wraps Board + Renderer — `fill()`, `render()`, `fillAndRender()`
- ✅ `AsciiRenderer(StylerType)` renders the full 9×9 grid with unicode borders, Styler seam for givens highlighting
- ✅ `main()` bootstraps GameEngine and renders initial board once
- ❌ No stdin command parsing — game exits after initial render
- ❌ No Validator — conflicts between digits across row/col/box are not detected or marked

### Command Type + Parser

_New module: `src/command.zig`_

A `Command` tagged union and a parser that turns player input lines into commands.


```zig
pub const Command = union(enum) {
    fill,   /// cell reference + digit  (e.g. "fill A1 7")
    clear,  /// cell reference  (e.g. "clear A3")
    quit,
};
```


Coordinate addressing: chess-style (A1 = column A, row 1 through I9) mapped to `(row, col)` 0-based indices. Parser returns `ParseError!Command` — bad input is a parse error handled at the stdin boundary in main, not folded into Command itself.

### GameEngine extensions
- Introduce `exec(cmd: Command) anyerror!void` — routes fill/clear/quit through existing Board mutations, re-renders on success.
- Existing `fill()` and `clearCell()` become internal helpers behind the new `exec()` gate.
- `quit` command returns a control signal that main's loop interprets as exit.

### Validator (new module: `src/validator.zig`)
_Wired into GameEngine after each mutation._

Given Board state, walks all 9 rows, 9 columns, and 9 Boxes via Grid topology views. Flags any cell whose digit appears more than once in its row/col/box scope. Returns conflict information back to GameEngine, which marks cells on the Board's conflict state so the Styler can decorate them.

Validator responsibilities:
- Check each non-empty cell against its peer set (row + col + box)
- Report per-cell conflict: is this cell's digit duplicated in any of its three scopes?
- Not fallible — always returns a result, never errors

### Main command loop

_Updated `src/main.zig`_


```zig
// pseudo-code
var engine = try GameEngine(R).init(puzzle_str, &renderer);
while (true) {
    print(">");
    line = reader.readUntilDelimiterOrEof(buf, '\n') catch break;
    cmd = parse(line) catch |err| { std.log.warn("bad command: {}", .{err}); continue; };
    switch (cmd) {
        .quit => break,
        else => try engine.exec(cmd),
    }
}
```


Loop stays tight — no curses/TUI. Stdin/stdout is sufficient for interactive play validation.

## Acceptance criteria
- [ ] `Command` tagged union defined with fill/clear/quit variants

- [ ] Parser converts chess-style input (e.g., "fill A1 7") to Command struct
- [ ] GameEngine gains `exec(Command)` entry point behind the event loop
- [ ] Validator detects conflicts across row/col/box using Grid RowView/ColView topology
- [ ] Conflicting cells are visually distinguished in the rendered output (via Styler)
- [ ] Given/prefilled cells cannot be altered by player input
- [ ] Main event loop runs: render → read input → exec command → re-render
- [ ] quit command exits cleanly
- [ ] Parse errors are caught in main and reported without crashing

## Blocked by
(none — Board, GameEngine, AsciiRenderer, Styler seam all delivered)

### Note on issue 05
Issue 05 (puzzle loading and difficulty levels) is a sibling concern, not a blocker. The command loop in this issue will start with a single embedded puzzle; once the Command/Parser infrastructure exists, `new_puzzle <difficulty>` becomes a natural extension of that same layer.
