Status: closed
Type: task
Blocked by: 02-game-engine-exec, 04-exec-wires-validator, 05-styler-conflict-decoration


### Architecture

| Layer | File | Responsibility |
|-------|------|----------------|
| Bootstrap | `main.zig` | wire up IO, logger, styler, renderer — create config — call `Sudoku.run()` and return on exit |
| Orchestrator | `sudoku.zig` (new) | owns the R→P→L→Pr→Sw→E command loop, `waitAck`, parse→exec routing, holds GameEngine + Config |
| Engine | `game_engine.zig` | Board mutation, exec(), render delegation — unchanged |
| Config | `config.zig` (new) | nominal config struct with hard-coded defaults (renderer type reference, difficulty) |
Rewrite `sudoku.zig` to the command loop anatomy from the parent issue's preamble. The Orchestrator layer owns stdin, command parsing, the R→P→L→Pr→Sw→E loop and the acknowledge gate — GameEngine handles Board mutation and rendering as before.

| Piece | Role | Owner |
|-------|------|-------|
| R — Render | `engine.render()` | sudoku.zig delegates to GameEngine |
| P — Prompt | `print("> ")` | sudoku.zig |
| L — Read line | `readUntilDelimiterOrEof(buf, '\n')`; EOF → break | sudoku.zig |
| Pr — Parse | `command.parse(line)` → ParseCommandResult | command (as is) |
| Sw — Switch | `.valid` → exec; `.invalid_message` → acknowledge + continue | sudoku.zig |
| E — Exec | `engine.exec(cmd)` → CommandResult | game_engine (as is) |
| A — Acknowledge gate | print message, consume Enter press, loop continues | sudoku.zig |
### Verify before code
Current `main()` calls `engine.render()` once then returns. P, L, Pr, Sw, A pieces don't exist yet as code.

Validator is now wired in engine.init() (`validateBoard` — full scan) and engine.exec() (`refreshConflictsForCell` — incremental).

### Test (write first)
T6 is too integration-heavy for inline tests — verify via manual run instead.

### Code (write after test)

#### `src/config.zig` (done)
- `Config` struct with a `difficulty` field (`puzzle_gen.Difficulty`)
- `Config.default()` returns hard-coded defaults for now

#### `src/sudoku.zig` (new)
1. `Sudoku.init(cfg: Config, renderer: *R) GameEngine(R)` — create engine from config difficulty + renderer
2. `fn run(self: *@This(), init: std.process.Init) anyerror!void` — enter `while (true)` loop
3. R — `self.engine.render()` (full redraw, always first iteration)
4. P — print `"> "` prompt
5. L — read line from stdin; EOF or error → break
6. Pr — result = `command.parse(line)`
7. Sw — on `.valid`: route to exec; on `.invalid_message`: call `waitAck(msg); continue`
8. E — execResult = `try self.engine.exec(cmd)`:
   - `.quit` → break (exit program)
   - `.ok` → loop continues immediately
   - `.error_msg` → `waitAck(msg); continue`
9. Loop repeats from R

Define `fn waitAck(writer: anytype, msg: []const u8) anyerror!void`:
- Write error message + newline to stdout via writer
- Prompt `"> "` (press Enter to continue)
- Read empty line from stdin
- Loop continues after acknowledgement

#### `src/main.zig` (simplified)
1. bootstrap: create IO writers, logger, styler, Ascii renderer (largely unchanged setup steps)
2. `const cfg = Config.default();`
3. `var sudoku = Sudoku(R).init(cfg, &r);`
4. call `sudoku.run(init)` — main returns when run returns
### Verify after (manual run)
- `zig build run` renders board, prompts `> `
- Type `fill A1 7` (empty cell) → cell updates on next render, loop continues
- Type `fill given_cell` → error message displayed, press Enter, prompt returns
- Type garbage → parse rejection displayed, press Enter, prompt returns
- Type `quit` → program exits cleanly
- `zig test src/root.zig` all prior tests still pass (T6 is main-level integration; coverage comes through manual run)
