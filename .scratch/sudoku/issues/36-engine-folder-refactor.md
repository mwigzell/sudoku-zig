
## Parent
Issue 29 (renderer-facade) — consolidation of command layer before final wiring.

## What to do

Move `game_engine.zig` and the engine-operation command handlers into a new `src/engine/` folder. This clarifies the boundary between "parsing user input" (`command/`) and "executing actions on game state" (`engine/`).

### Current layout (wrong)
```
src/command/fill.zig          # calls engine.tryFill()
src/command/clear.zig         # calls engine.tryFill(row, col, .zero)
src/command/undo.zig          # mutates engine.history, engine.board
src/command/redo.zig          # mutates engine.history, engine.board
src/command/save.zig          # delegates to save_as, uses engine state
src/command/save_as.zig       # calls engine.saveGame(), resolves paths
src/command/open.zig          # deserializes into engine
src/command/quit.zig          # returns quit event with board view
src/command/new.zig           # resets history, loads puzzle into engine
src/command/path.zig          # path utilities used by save/open
src/command/mutation_history.zig  # data struct for undo/redo (engine concern)

src/game_engine.zig           # the domain model
```

### Target layout
```
src/engine/game_engine.zig    # moved from top-level
src/engine/fill.zig           # moved from command/
src/engine/clear.zig          # moved from command/
src/engine/undo.zig           # moved from command/
src/engine/redo.zig           # moved from command/
src/engine/save.zig           # moved from command/
src/engine/save_as.zig        # moved from command/
src/engine/open.zig           # moved from command/
src/engine/quit.zig           # moved from command/
src/engine/new.zig            # moved from command/
src/engine/path.zig           # moved from command/
src/engine/mutation_history.zig  # moved from command/

src/command/parse.zig         # stays — parsing only
src/command/disambiguate.zig  # stays — input disambiguation
src/command/legend.zig        # stays — help text
```

Rationale: `engine/` owns all GameEngine mutation. `command/` owns only string→struct conversion and routing metadata.

## Steps (each a separate commit)

### Step 1 — Create `src/engine/`, move files, fix internal engine imports

**Move:**
- `src/game_engine.zig` → `src/engine/game_engine.zig`
- `src/command/{fill,clear,undo,redo,save,save_as,open,quit,new,path,mutation_history}.zig` → `src/engine/`

**Fix inside `engine/` (12 files):**

`game_engine.zig` — 9 imports change (L133-143):
```diff
-const mutation_history = @import("command/mutation_history.zig");
 -const fill_command = @import("command/fill.zig");
 -const clear_command = @import("command/clear.zig");
 -const undo_command = @import("command/undo.zig");
 -const redo_command = @import("command/redo.zig");
 -const quit_command = @import("command/quit.zig");

- const open_command = @import("command/open.zig");

- const save_as_command = @import("command/save_as.zig");
 -const mypath = @import("command/path.zig");
+const mutation_history = @import("mutation_history.zig");
+const fill_command = @import("fill.zig");
+const clear_command = @import("clear.zig");
+const undo_command = @import("undo.zig");
+const redo_command = @import("redo.zig");
+const quit_command = @import("quit.zig");

+const open_command = @import("open.zig");

+const save_as_command = @import("save_as.zig");
+const mypath = @import("path.zig");
```

Each of the 11 handler files — `@import("../game_engine.zig")` → `@import("game_engine.zig")`.
Handler cross-references within command/ also tighten (e.g. clear.zig's `@import("fill.zig")` stays same since both are now siblings).

### Step 2 — Fix imports in callers **outside** engine

**`src/root.zig`** (L4, L15-26) — 10 import paths change:
```diff
 -const game_engine = @import("game_engine.zig");
+const game_engine = @import("engine/game_engine.zig");

 -const mutation_history = @import("command/mutation_history.zig");
 -const path = @import("command/path.zig");
 -const fill = @import("command/fill.zig");
 -const clear_command = @import("command/clear.zig");
- const undo_command = @import("command/undo.zig");
 -const redo_command = @import("command/redo.zig");
 -const quit_command = @import("command/quit.zig");

+const save_as_command = @import("command/save_as.zig");
 -const open_command = @import("command/open.zig");
+const mutation_history = @import("engine/mutation_history.zig");
+const path = @import("engine/path.zig");
+const fill = @import("engine/fill.zig");
+const clear_command = @import("engine/clear.zig");
+const undo_command = @import("engine/undo.zig");
+const redo_command = @import("engine/redo.zig");
+const quit_command = @import("engine/quit.zig");

+const save_as_command = @import("engine/save_as.zig");
+const open_command = @import("engine/open.zig");
```

**`src/sudoku.zig`** (L3, L11):
```diff
 -const game_engine = @import("game_engine.zig");
- const mypath = @import("command/path.zig");
+const game_engine = @import("engine/game_engine.zig");
+const mypath = @import("engine/path.zig");
```

**`src/renderer/ascii/ascii_renderer.zig`** (L247):
```diff
- const game_engine = @import("../../game_engine.zig");
+const game_engine = @import("../../engine/game_engine.zig");
```

**`src/renderer/facade.zig`** (L13):
```diff
 -const AvailableCommands = @import("../game_engine.zig").AvailableCommands;
+const AvailableCommands = @import("../engine/game_engine.zig").AvailableCommands;
```

**`src/renderer/mock/mock_renderer.zig`** (L7):
```diff
- const AvailableCommands = @import("../../game_engine.zig").AvailableCommands;
+const AvailableCommands = @import("../../engine/game_engine.zig").AvailableCommands;
```

### Step 3 — Verify

```bash
zig build test   # all tests pass
zig build run    # CLI works
```

Delete the old `src/command/` files only after confirming green (git mv is safest).

## Acceptance criteria

- [ ] `src/engine/` contains `game_engine.zig` + 11 handler/utility files
- [ ] `src/command/` retains only: `parse.zig`, `disambiguate.zig`, `legend.zig`
- [ ] All imports updated in: `root.zig`, `sudoku.zig`, `ascii_renderer.zig`, `facade.zig`, `mock_renderer.zig`
- [ ] Full test suite passes (217+ tests)
- [ ] `zig build run` works (CLI output + grid render)
