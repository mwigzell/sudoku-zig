## What to build

Move filename state out of `GameEngine` and into the Renderer. Make `.save`, `.save_as`, and `.open` all flow through their parsed command data — `exec()` just uses what it gets, no defaulting or substitution.

### Design decisions

1. **`GameEngine.filename: ?[]u8` → removed.** It is not engine responsibility to remember a filename.
2. **"Last saved filename" lives in the Renderer** (`AsciiRenderer`, `MockRenderer`). Stored as `last_filename: ?[]const u8` on the renderer struct.
3. **`getCommandInput()` populates the parsed command's path fully.** By the time `exec()` sees a `.save`, `.save_as`, or `.open` command, the `SaveData.path` or `OpenData.path` is already filled with the resolved filename.
4. **`DEFAULT_SAVE_FILE`** stays in `command/save.zig` (already exported) and is used as the prompt default — not baked into parsed commands.

### Memory ownership

`SaveData.path` and `OpenData.path` are non-optional `[]const u8`. The renderer populates them with owned strings. GameEngine passes them through unchanged.

When caching `last_filename`, the intercept uses shared ownership: dialog allocates ONE string, both SaveData.path and self.last_filename point to it. No duping — renderer deinit frees.


### Current wiring vs target

| Command | Now | Target |
|---------|-----|--------|
| `.save` | Parser bakes hardcoded path into `SaveData`. `save.execute()` ignores it, checks `engine.filename`, falls back to `DEFAULT_SAVE_FILE`. | `getCommandInput()` intercepts `.save` → checks renderer `last_filename`: if non-null use it, else call `saveAsDialog(DEFAULT_SAVE_FILE)` to prompt. Either way populates `SaveData.path`. `save.execute()` uses exactly what it gets. |
| `.save_as` | `getCommandInput()` already intercepts and calls `saveAsDialog()`. Path is overwritten into `SaveData.path`. Still bakes a dummy default at parse time. | Same interception, but renderer also caches the chosen name as `last_filename` for future `.save`. Parser no longer bakes a dummy path. |
| `.open` | User types `open <filename>` — parser extracts filename from stdin. `open.execute()` receives it. | `getCommandInput()` intercepts `.open` → calls `openDialog()`, populates `OpenData.path`. `open.execute()` uses exactly what it gets. No user-typed filename. |

### Steps

| # | Description |
|---|-------------|
| 1 ⛔ | Make types nullable → REJECTED after panics. Types remain non-optional `[]const u8` with path always set by intercept.
| 2 ✅ | Add `last_filename: ?[]u8` (owned) to `AsciiRenderer`. Update init/deinit. No need for MockRenderer — it doesn't use file dialog.
| 3 ✅ | Modify `.save` intercept: check `self.last_filename`. If present, point SaveData.path at cache directly. If null, call `saveAsDialog(DEFAULT_SAVE_FILE)`, cache result. Shared ownership (no dupe).
| 4 ✅ | After `.save_as`: cache chosen name as `last_filename`, free old first. SaveData.path points at same allocation.
| 5 | Modify `.open` intercept in `getCommandInput()`: call `openDialog()` and populate `OpenData.path`. Cancelled returns error_msg.
| 6 ⛔ | Rejected with nullable types — paths are non-optional, no freeing needed in exec.
| 7 ✅ | `engine.filename` already removed (issue 25 cleanup) — save.execute() uses passed path directly.
| 8 ✅ | `engine.filename` already removed — save_as.execute() uses passed path, no caching on engine.
| 9 | Remove `engine.filename: ?[]u8`, `engine.last_save_msg: ?[]u8` from `GameEngine`. (Partial — filename gone, last_save_msg remains.)
| 10 ✅ | All tests updated to not reference engine filename.

### Acceptance criteria

- [x] 1. `GameEngine` has no `filename` field. (Removed in earlier issue 25 cleanup.)
- [x] 2. `AsciiRenderer` stores `last_filename`. After a successful save, subsequent `.save` does not prompt and writes to the same file.
- [x] 3. `.save` with no prior filename calls `saveAsDialog()` and prompts user.
- [x] 4. After `.save_as`, the chosen filename is cached; subsequent `.save` reuses it without prompting.
- [ ] 5. `.open` does not require user-typed filename — uses `openDialog()`. (Step 5, not yet implemented.)
- [x] 6. `exec()` passes path data through unchanged - `.save`, `.open`, `.save_as` all call their handler with `data.path` directly.
- [x] 7. `parse.zig` has no hardcoded save filenames — paths are set by intercept.
- [ ] 8. All existing tests pass (or are updated). No new failures introduced.
