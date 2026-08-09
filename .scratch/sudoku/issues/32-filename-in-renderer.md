## What to build

Move filename state out of `GameEngine` and into the Renderer. Make `.save`, `.save_as`, and `.open` all flow through their parsed command data — `exec()` just uses what it gets, no defaulting or substitution.

### Design decisions

1. **`GameEngine.filename: ?[]u8` → removed.** It is not engine responsibility to remember a filename.
2. **"Last saved filename" lives in the Renderer** (`AsciiRenderer`, `MockRenderer`). Stored as `last_filename: ?[]const u8` on the renderer struct.
3. **`getCommandInput()` populates the parsed command's path fully.** By the time `exec()` sees a `.save`, `.save_as`, or `.open` command, the `SaveData.path` or `OpenData.path` is already filled with the resolved filename.
4. **`DEFAULT_SAVE_FILE`** stays in `command/save.zig` (already exported) and is used as the prompt default — not baked into parsed commands.

### Memory ownership

`SaveData.path` and `OpenData.path` are `?[]const u8`. The renderer (intercept in `getCommandInput`) allocates or dupes the string before returning. GameEngine `exec()` consumes the Command and frees `data.path.?` via page_allocator after use.

When caching `last_filename` on the renderer, the intercept dupes rather than transferring ownership — so exec's free doesn't touch the cache copy.

### Current wiring vs target

| Command | Now | Target |
|---------|-----|--------|
| `.save` | Parser bakes hardcoded path into `SaveData`. `save.execute()` ignores it, checks `engine.filename`, falls back to `DEFAULT_SAVE_FILE`. | `getCommandInput()` intercepts `.save` → checks renderer `last_filename`: if non-null use it, else call `saveAsDialog(DEFAULT_SAVE_FILE)` to prompt. Either way populates `SaveData.path`. `save.execute()` uses exactly what it gets. |
| `.save_as` | `getCommandInput()` already intercepts and calls `saveAsDialog()`. Path is overwritten into `SaveData.path`. Still bakes a dummy default at parse time. | Same interception, but renderer also caches the chosen name as `last_filename` for future `.save`. Parser no longer bakes a dummy path. |
| `.open` | User types `open <filename>` — parser extracts filename from stdin. `open.execute()` receives it. | `getCommandInput()` intercepts `.open` → calls `openDialog()`, populates `OpenData.path`. `open.execute()` uses exactly what it gets. No user-typed filename. |

### Steps

| # | Description |
|---|-------------|
| 1 ✅ | Make `SaveData.path` and `OpenData.path` nullable (`?[]const u8`). Remove comptime default from parser — leave null, populated by intercept instead (parser just sets other fields like row/col/digit).
| 2 ✅ | Add `last_filename: ?[]u8` (owned) to `AsciiRenderer`. Update init/deinit. No need for MockRenderer — it doesn't use file dialog.
| 3 ✅ | Modify `.save` intercept in `getCommandInput()`: check `self.last_filename`. If present, dupe into `SaveData.path` (exec will free). If null, call `saveAsDialog(save.DEFAULT_SAVE_FILE)` to prompt, assign owned result directly. (DONE — but uses shared ownership instead of duping for memory safety.)
| 4 ✅ | After successful `.save_as` intercept: cache chosen name as `last_filename` (free old first) via dupe. Original assigned to command for exec. (DONE alongside Step 3.)
| 5 | Modify `.open` intercept in `getCommandInput()`: call `openDialog()` and populate `OpenData.path`. Cancelled returns error_msg.
| 6 | Add `defer std.heap.page_allocator.free(data.path.?);` in each exec switch case (.save, .open, .save_as) so the consumed command's path is freed after use.
| 7 | Simplify `save.execute()`: remove `engine.filename == null` fallback and engine-owned filename handling. Just use passed path directly from command data.
| 8 | Simplify `save_as.execute()`: remove `engine.filename` caching. Still saves to disk.
| 9 | Remove `engine.filename: ?[]u8`, `engine.last_save_msg: ?[]u8` from `GameEngine`. Clean up deinit, init. Update Open command handler to not touch engine-owned filename fields.
| 10 | Update all tests that reference `engine.filename` or assume user-typed open paths.

### Acceptance criteria

- [ ] 1. `GameEngine` has no `filename` field.
- [ ] 2. `AsciiRenderer` stores `last_filename`. After a successful save, subsequent `.save` does not prompt and writes to the same file.
- [ ] 3. `.save` with no prior filename calls `saveAsDialog()` and prompts user.
- [ ] 4. `.open` does not require user-typed filename — uses `openDialog()`.
- [ ] 5. `exec()` passes path data through unchanged — no defaulting logic in command handlers.
- [ ] 6. `parse.zig` has no hardcoded save filenames.
- [ ] 7. All existing tests pass (or are updated).
