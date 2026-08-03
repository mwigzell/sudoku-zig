Status: ready-for-human





## Parent

`.scratch/sudoku/prd.md` (refactor)

## What to build

Two things: **one file per command** and **restore exec() as the single dispatch surface**.

### Problem 1 — game_engine.zig should not be a monolith

Each command's implementation should live in its own file under `src/command/`.
This is hygiene: stop stuffing everything into one file. exec()'s switch body
already has inline paragraphs for fill/clear/undo/redo — each of those deserves
its own module.

Related modules that belong with commands move too: `legend.zig`,
`disambiguate.zig`, `path.zig` (save/open I/O helpers), and `undo.zig`
(MutationHistory lives next to undo).

### Problem 2 — exec() isn't the dispatch surface it should be

Currently `handleResult()` in `sudoku.zig` intercepts `.quit`, `.save`, and
`.open` before they reach `exec()`, bloating the dispatch layer with path
resolution, filename persistence, and message construction. Root cause:
`GameEngine.init()` took no Io handle, so save/open couldn't live in exec().
Fix by threading Io through GameEngine's constructor.

### After — one file per command

```
src/command/
  disambiguate.zig   ← moved
  fill.zig           ← new (extracted from game_engine)
  clear.zig          ← new
  path.zig           ← moved
  legend.zig         ← moved
  mutation_history.zig  ← renamed from undo.zig, moved
  undo.zig           ← new (command handler)
  redo.zig           ← new
  save.zig           ← new (from handleResult interception)
  open.zig           ← new (from handleResult interception)
```

### After — exec()

```zig
fn exec(self: *@This(), cmd: Command) Event {
    switch (cmd) {
.fill => |data| command.fill.execute(self, data),
.clear => |data| command.clear.execute(self, data),
.undo   => |_|  command.undo.execute(self),
.redo   => |_|  command.redo.execute(self),
.save   => |_|  command.save.execute(self),
.open   => |d|  command.open.execute(self, d.path),
.quit   => |_|  command.quit.execute(self),
    }
}
```

### After — handleResult()

```zig
fn handleResult(...) {
.valid => |cmd| {
        const event = try self.engine.exec(cmd);
        if (isQuitEvent(event)) return true;
        return try self.handleEvent(out, in_, renderer, event);
    }
}
```

### Fields that move from Sudoku → GameEngine

| Field | Current owner | New owner | Reason |
|-------|---------------|-----------|--------|
| `_dataDir: ?[]u8` | Sudoku | GameEngine | Only used by save/open commands, both now in exec() |
| `_filename: ?[]u8` | Sudoku | GameEngine | Persists filename across saves, accessed by save handler |
| `_lastSaveMsg: ?[]u8` | Sudoku | GameEngine | Carries feedback message back through Event.ok.msg |

| Step | Description | Target file(s) | Tests |
|------|-------------|----------------|-------|
| 1 ✅ | Add `_io: std.Io` field to GameEngine struct; update `init(puzzle_str, io)` to accept and store Io. | `game_engine.zig` | Compile + existing tests pass with new init signature |
| 2 ✅ | Create `src/command/`. Move `undo.zig → command/mutation_history.zig`, `command.zig → command/parse.zig`. Move `path.zig`, `legend.zig`, `disambiguate.zig` into `command/`. Update all import paths. | multiple (structural only) | Compile, 0 behavioral changes — pure import surgery |
| 3 ✅ | Extract existing exec() cases: fill → `command/fill.zig`, clear → `command/clear.zig`, undo → `command/undo.zig`, redo → `command/redo.zig`. Each exports `fn execute(g: *GameEngine, ...) Event`. Replace inline switch bodies with calls. | `src/command/*.zig`, `game_engine.zig` | Existing fill/clear/undo/redo tests still pass — same behavior, different home |
| 4 ✅ | Add `command/save.zig`, `command/open.zig` and wire .quit through exec() — move save/open/quit interception from handleResult into exec() cases. Uses GameEngine's `_io` field for disk I/O. Path resolution via `command/path.zig`. Quit handler sets `_is_quit: bool` on Event.ok to signal loop exit. | `src/command/save.zig`, `src/command/open.zig`, `game_engine.zig` | Acceptance Criteria: 1) Each command handler (fill/clear/undo/redo/save/open/quit) has its own file under `src/command/` 2) exec() switch delegates to those handlers, no inline bodies.
| 5 | Collapse handleResult: remove all interception blocks. Every command → `exec(cmd)` + `handleEvent(event)`. Remove `_dataDir`, `_filename`, `_lastSaveMsg` from Sudoku struct (now on GameEngine). Quit breaks loop via `_is_quit` flag in Event.ok, not handleResult special-case. | `sudoku.zig`, `game_engine.zig` | All integration tests pass through simplified path
| 6 | Update all test sites constructing GameEngine to pass `std.testing.io` as second arg. ~50 call sites. Update root.zig imports for new module paths. Run full suite + coverage. | multiple | All 179+ tests pass, coverage holds


### How quit breaks the loop
Quit processes through exec() like every other command — no interception in handleResult().
The `event.ok` struct carries an `_is_quit: bool` flag set by the quit handler.
handleResult() checks that flag and returns true to break the command loop.
This keeps exec() as the single dispatch surface with zero exceptions.


## Acceptance Criteria

- [x] `GameEngine.init()` signature is `init(puzzle_str, io) → !GameEngine`
- [x] `_io` field stored on GameEngine struct  
- [x] Each command (fill/clear/undo/redo/save/open/quit) has its own handler under `src/command/`
- [x] exec() switch is flat: one function call per case, no inline logic
- [x] MutationHistory moved to `command/mutation_history.zig`, lives beside undo handler
- [x] legend/disambiguate/path move into `src/command/` sub-folder  
- [x] parse types (Command enum, FillData etc) moved to `command/parse.zig`
- [ ] handleResult dispatches every command through exec() — no fat switch
- [ ] `_dataDir`, `_filename`, `_lastSaveMsg` on GameEngine struct (removed from Sudoku)
- [x] Save, Open and Quit handled in exec() (no interception in handleResult) — quit sets `_is_quit: bool` on Event.ok to signal loop exit
- [x] All existing tests pass, no behavioral changes
- [x] Coverage holds at or above 98%

