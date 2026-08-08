## Triage
ready-for-human

### Notes
- Axis: WASM compatibility. Current stdin coupling blocks browser rendering entirely.
- Depth: medium refactor — changes the Renderer contract from "draw-only" to "widget facade".
- Impacts `renderer/facade.zig`, `sudoku.zig` (command loop), ascii & mock renderers, and any future WASM renderer.



## Parent
`.scratch/sudoku/prd.md`

## Working mode
HITL. Design the facade interface first; implementation TDD per step.

## What to build

The **Renderer** should be a **widget facade** — rendering output and gathering structured input. Each method maps to a *specific UI element*, so every renderer shapes that element however it wants:

| Widget | Terminal | WASM (future, issue 03) |
|---|---|---|
| `render` + status bar | clear + draw | full DOM re-render |
| legend / command bar | print line | bottom toolbar buttons |
| error modal | "press Enter" | click-to-dismiss overlay |
| save dialog | stdin prompt for filename | `<input type="file">` or text input |
| open dialog | stdin path read | native file picker |
| new-game choices | menu keys 1/2/3/4/5 | radio buttons + text area |
| getCommandInput | readLine → parse → Command | structured input → parse → Command |

The command loop no longer reads stdin. It calls structured renderer methods and gets structured data back — never raw strings from a prompt.

### Current problem (why this is needed)

`sudoku.zig` reads directly from `Io.File.stdin().reader`. WASM has no stdin, so user input must flow through the same abstraction layer as output. Today all UI besides board rendering is ad-hoc in `sudoku.zig`:

- `readLine()` — raw stdin for commands
- `waitAck()` — press Enter after errors
- inline save-as filename prompt inside `promptForAndRunCommand` (legacy conflation of save/save_as)
- `printLegend()` — writes directly to stdout writer

#### I/O Ownership Decisions (confirmed with user)
- **AsciiRenderer stores:** `io: std.Io`, `writer: *Io.Writer`, `allocator: std.mem.Allocator`, `styler: *StylerType`.
- **Reader NOT stored as pointer.** Zig readers wrap stack buffers. Each read method creates a local stack buffer + reader inline.
- **readLine() helper returns `Error!?[]u8`.** Uses allocator to dupe; caller owns the string via `defer allocator.free(line)`.

**Source of truth:** `src/renderer/facade.zig` (renderer vtable, Make(CT), dispatchers) and `src/command/parse.zig` (Command, ParseCommandResult, SaveData, OpenData).

### The run() cycle

The command loop lives in `sudoku.zig` `run()`. After this issue completes, it becomes a clean renderer-only loop:

```
  renderer.render(view, msg)
       ↓
  renderer.getCommandInput(avail)        ← prompt → parse → Command (sub-dialogs handled internally)
       ↓
  engine.exec(cmd)                     ← mutates board, returns Event
       ↓
  check Event.is_quit → next iteration or exit
```

Old code: `render(out)` → `promptForAndRunCommand(in_, out)` [raw stdin] → `exec(cmd)` → event.
New code: all UI flows through the renderer.


### Implementation Steps

**Step 1** — `getCommandInput`: prompt → parse → exec command flow

Each row maps to one TDD iteration. Rows 1–5 are passthrough (no change needed).
Row 6 (save) is passthrough — uses current filename or default, no prompting.
Rows 7–9 are the sub-dialog rows where getCommandInput intercepts and packages data into a Command.

| Command | User input | `getCommandInput` action | Returns (`ParseCommandResult`) | `exec(Command)` data | Notes |
|---------|-----------|------------------------|-------------------------------|---------------------|-------|
| fill | `fill A1 7` | parse → dispatchToParser | `.valid{.fill: FillData}` | `fill_command.execute(self, data)` | Passthrough, no change |
| clear | `clear B3` | parse → dispatchToParser | `.valid{.clear: ClearData}` | `clear_command.execute(self, data)` | Passthrough, no change |
| undo | `u` / `undo` | parse → dispatchToParser | `.valid{.undo: void}` | `undo_command.execute(self)` | Passthrough, no change |
| redo | `r` / `redo` | parse → dispatchToParser | `.valid{.redo: void}` | `redo_command.execute(self)` | Passthrough, no change |
| quit | `q` / `quit` | parse → dispatchToParser | `.valid{.quit: void}` | `quit_command.execute(self)` | Passthrough, no change |
| save | `save` | parse → dispatchToParser | `.valid{.save: SaveData}` | `save_command.execute(self, data)` | Passthrough — uses current filename or default |
| save_as | `save-as` / `saves` | detect .save_as tag → call `self.saveDialog()`. On `.FileName` → return Command with path. On `.Cancelled` → `.error_msg` | `.valid{.save_as: SaveData{path}}` | `save_command.execute(self, data.path)` | **SaveAs — prompts for filename** |
| open | `open` | detect .open tag → call `self.openDialog()`. Same pattern | `.valid{.open: OpenData{path}}` | `open_command.execute(self, data.path)` | Path from dialog, not tokenizer |
| new | `new` | detect .new tag → call `self.newGameOptions()`. On `.PuzzleString` → return Command. On `.Cancelled` → `.error_msg` | `.valid{.new: NewData{puzzle}}` | `new_command.execute(self, data.puzzle)` | **NewData struct**, replaces bare `void` |


**Edge cases:**
- EOF / read error in getCommandInput → treated as quit (`.valid{.quit: void}`)
- Empty line → `.error_msg("empty input")` → loop shows via showError and repeats



**Step 1a** — `.saveTag` interception in getCommandInput
- When parsed tag is `.save_tag`, detect it, call `self.saveDialog()` to prompt for filename.
- On `.FileName` — return valid save command with chosen path
- On `.Cancelled` — return error_msg

**Step 1b** — `.openTag` interception in getCommandInput
- When parsed tag is `.openTag`, detect it, call `self.openDialog()` to prompt for file path.
- On `.FileName` — return valid open command with chosen path
- On `.Cancelled` — return error_msg

**Step 1c** — `.new` interception + un-stub newGameOptions menu in getCommandInput
- When parsed tag is `.new`, detect it, call `self.newGameOptions()` to show menu.
- Un-stub: present menu "Generated / Medium / Hard" so user's key choice determines puzzle.
- On `.PuzzleString` — return valid new command with puzzle data
- On `.Cancelled` — return error_msg
**Step 2** — Wire renderer into `sudoku.zig` end-to-end

Replace the raw renderer param with a renderer pointer so all I/O flows through the vtable. This is **a switch, not a rewrite**: the backbone loop (`handleResult` → `handleEvent` → `engine.exec`) stays identical; only the I/O calls change.

**Step 2a** — `main.zig`: wrap AsciiRenderer through `Make(AsciiRenderer).make()`
- Create renderer as now.
- Add: `const F = facade.Make(ascii_renderer.AsciiRenderer(styler.AnsiStyler));`
- Pass the returned renderer into Sudoku init instead of raw `*R` + comptime type param.
- **Tests in place:** No existing test exercises `main.zig` directly. The init tests (#182, #197, #429) exercise `Sudoku(MockRenderer).init()` which will need updating once Step 2b changes the struct sig.

**Step 2b** — Replace `comptime R: type` parameter with `renderer: *Facade`
- Change `pub fn Sudoku(comptime R: type)` to accept a `*Facade` field instead of `renderer: *R`. Store `renderer: *Facade` on the struct.
- Update `init(cfg, _r, io)` sig: last param becomes `renderer: *Facade`, stored directly. No comptime type.
- **Tests in place:** Tests #182, #197, #429 all construct via `Sudoku(mock_renderer.MockRenderer).init(cfg, &mock, std.testing.io)`. They'll break when this step applies and need updating to create a renderer from MockRenderer instead. (This is the same update as Step 2a but from the test side.)

**Step 2c** — Replace `printLegend(out)` with `renderer.showLegend(avail)` in `handleEvent`
- **Current:** handleEvent line ~67 calls `self.printLegend(out)` passing a raw writer.
- **Change:** Replace with `self.renderer.showLegend(self.engine.getAvailableCommands())`.
- The existing `printLegend()` method itself can be retired later (after 2d) once nothing else references it. For now just replace the call site.
- **Tests in place:** Test #440 (`full seam: f A3 4`) asserts that `Command:` appears in mock writer output — this breaks because printLegend won't write to MockWriter anymore. Needs updating to check renderer was called instead (e.g., via a call_count on the renderer's showLegend_fn, or removing the assertion since it's covered by handleEvent's own render test).

**Step 2d** — Replace `waitAck(out, in_, msg)` with `renderer.showError(msg)` in `handleEvent`, `handleResult`
- **Current sites (4 total):**
  - handleEvent line ~72: `.error_msg` branch → `self.waitAck(out, in_, msg)`
  - handleResult line ~82: parse error_msg → `self.waitAck(out, in_, msg)`
  - handleResult line ~89: exec failure bufPrint → `self.waitAck(out, in_, msg)`
  - handleResult line ~95: handleEvent failure bufPrint → `self.waitAck(out, in_, msg)`
- **Change:** All four become `try self.renderer.showError(msg)`. The renderer's showError already handles writing the message + pressing Enter (proven in Step 1d).
- After this step, `waitAck()` is unused and can be removed along with its `reader` arg from any signature that only existed to pass it through.
- **Tests in place:** Tests #483 (`full seam: open loads saved game`), #536 (save success feedback), #576 (open success feedback), #621 (relative path no panic), #654 (save default filename), #685 (subsequent save reuse) all exercise `handleResult` with MockReader for waitAck. After this step, the `in_` param is no longer needed by handleResult so tests can drop MockReader entirely for error-msg scenarios.

**Step 2e** — Replace raw prompt + parse in `promptForAndRunCommand` with `renderer.getCommandInput(avail)`
- **Current:** lines ~103-116: `out.print("> "` → `readLine(in_)` → trim → `command.parseWithCommands(tokens, names)` → result.
- **Change:** Replace those ~12 lines with:
  ```zig
  const avail = self.engine.getAvailableCommands();
  const result = try self.renderer.getCommandInput(avail);
  ```
  The renderer handles prompt display, stdin read, trimming, and parse internally. Returns the ParseCommandResult directly.
- Also replace the save-specific prompt block (lines ~119-150) — that inline `out.print("Save to")` + `readLine(in_)` → dupe path is now handled by `getCommandInput` intercepting `.save_tag` and calling `saveDialog()` internally.
- After this step, the legacy inline save prompt code (lines ~118-153) is removed. The function becomes much thinner: one renderer call + switch on `.save` for first-save filename caching logic only.
- **Tests in place:** Test #440 (`full seam: f A3 4`) calls `promptForAndRunCommand(&mw, &mr)` with canned MockReader input `"f A3 4"`. After this step, promptForAndRunCommand takes no args and reads through the renderer instead. The test needs to set up a canned response on getCommandInput (either via MockRenderer overriding or by updating the test to exercise through a new integration path).

**Step 2f** — `run()`: remove local stdout_writer / stdin_reader creation, use renderer methods
- **Current:** lines ~159-174: creates `stdout_writer`, `stdin_reader`, passes `out`/`in_` through to promptForAndRunCommand.
- **Change:** Remove the writer/reader setup. Loop becomes:
  ```zig
  pub fn run(self: *@This()) anyerror!void {
      try self.renderer.render(self.engine.eventBoard(), null);
      try self.renderer.showLegend(self.engine.getAvailableCommands());

      var isDone: bool = false;
      while (!isDone) {
          isDone = try self.promptForAndRunCommand();
      }
  }
  ```
- All three method sigs that take `(out, in_)` are updated: `handleEvent(out, in_, event)` → `handleEvent(event)`, `handleResult(out, in_, result)` → `handleResult(result)`, `promptForAndRunCommand(out, in_)` → `promptForAndRunCommand()`.
- **Tests in place:** None of the existing tests call `run()` directly — they all exercise inner methods via MockReader/MockWriter. No direct test impact because the existing integration tests call `promptForAndRunCommand`, `handleResult` with mock I/O. After this step those args are dropped so test callsites update accordingly.

**Step 2g** — Remove `readLine()` helper (unused after Step 2e)
- Lines ~30-31: bare `fn readLine(reader)` on the struct. Only called from promptForAndRunCommand (lines ~106, ~140). Both replaced by renderer calls in Step 2e.
- **Tests in place:** No test references readLine directly. Cleanup step — no test churn.

**Step 2h** — Verify: `zig build run` full game loop + regression suite
- Run the binary, verify visually identical output (board render, legend, prompt, error handling, quit).
- All 204+ existing tests pass after their call sites are updated (comptime R → renderer, MockReader/MockWriter removed from handleResult/promptForAndRunCommand invocations).
- **Tests in place:** Full regression coverage exists — same assertions, just different plumbing. The backbone tests (#440, #483, #536, #576, #621, #654, #685) verify handleResult → event flow which is unchanged. Only the I/O call path differs, and those are verified by renderer's own unit tests from Steps 1a-1h.
**Step 3** — Adapt MockRenderer for testable widget-based flows

MockRenderer needs to work as a renderer implementation so integration tests can drive command flow without real I/O.

1. **Canned command input**: Add `next_command: ?ParseCommandResult` field and a flag. When set, `getCommandInput()` returns it instead of reading stdin.
2. **Mock widget methods**: Ensure `saveDialog()`, `openDialog()`, `newGameOptions()` are overridable (return canned results).

3. **renderer.Make(MockRenderer)**: Wire through Make() so tests construct a renderer from MockRenderer.
4. **Regression test matrix**: For each command type (fill, clear, undo, redo, quit, save, open, new), verify the renderer loop produces correct state changes — same assertions as existing `handleResult` tests but through renderer path.
5. **Verify**: All 200+ existing tests still pass. New renderer-path tests added.


---


## Acceptance criteria
- [x] Steps 1a–1g: renderer foundation — all seven methods implemented on AsciiRenderer with dispatchers & Make(CT) wrappers (render, showLegend, showError, saveDialog, openDialog, newGameOptions, getCommandInput)
- [ ] **Step 1a**: `.saveTag` interception in getCommandInput
- [ ] **Step 1b**: `.openTag` interception in getCommandInput
- [ ] **Step 1c**: `.new` interception + un-stub newGameOptions menu
- [ ] **Step 2**: Wire renderer into sudoku.zig end-to-end (letter sub-steps 2a–2h)
  - [x] 2a: `main.zig` wrap through Make().make()
  - [x] 2b: Replace `comptime R` with `renderer: *Facade`
  - [x] 2c: Replace printLegend → renderer.showLegend
  - [x] 2d: Replace waitAck (4 sites) → renderer.showError
  - [ ] 2e: Replace raw prompt + parse in promptForAndRunCommand → renderer.getCommandInput
  - [ ] 2f: run() remove local I/O creation, use renderer methods
  - [ ] 2g: Remove unused readLine helper
  - [ ] 2h: Verify zig build run + regression suite
- [ ] Step 3: Adapt MockRenderer for testable widget-based flows

## Blocked by
(none)

