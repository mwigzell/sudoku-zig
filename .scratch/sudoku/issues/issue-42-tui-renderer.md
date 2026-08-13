triage: needs-triage

## Implement TuiRenderer with cursor control and keyboard input

Real terminal UI renderer using screen control, cursor positioning, selective redraws, and direct key input. The third concrete renderer alongside AsciiRenderer and WasmRenderer.

Add `--tui` flag to `main.zig`. Users choose: `--ascii`, `--tui`, or default (`--ascii`).

### Context

AsciiRenderer streams full board + legend on every cycle. A proper TUI would:
- Take terminal control (raw mode, hide cursor)
- Position the cursor directly onto cells for navigation
- Redraw only what changed
- Capture keypresses instead of newline-delimited input
- Show active cell highlight (where the user's focus is)

### Steps

#### Step 1: Add `tui` to `RendererKind` config and `--tui` flag

Add `.tui` variant to `config.RendererKind`. Parse `--tui` CLI arg in `main.zig` (alongside existing `--ascii`). Wire through Facade.Make(TuiRenderer) when selected.

#### Step 2: Create `src/renderer/tui/tui_renderer.zig`

Module structure matching AsciiRenderer pattern:
- `TuiRenderer` struct with terminal state (raw mode handle, active cell coords)
- Implement all Facade vtable methods via terminal escape codes / std lib
- No ncurses dependency — use ANSI cursor positioning sequences directly to stdout (stays portable)

#### Step 3: Terminal init/teardown lifecycle

On `init()`: switch to raw/cbreak mode, hide cursor, clear screen.
On `deinit()`: restore terminal state, show cursor, reset mode.
Handle graceful cleanup on quit and errors.

#### Step 4: Implement `render` — full board with cursor overlay

Draw the board once on init, then update only changed cells by positioning the cursor at their coordinates. Maintain an "active cell" state (row, col) that renders with highlighting (bold/reverse), not streamed text.

#### Step 5: Implement `getCommandInput` — key capture

Instead of reading lines, read individual keypresses:
- Arrow keys / vim h,j,k,l → move cursor to adjacent cell
- Digit 1-9 → fill active cell
- Backspace/Delete → clear active cell
- Q → quit
- S → save, O → open, N → new game

No parse step needed — the TUI constructs `Command` values directly from key events (same principle as WASM mode). This eliminates the ASCII parsing layer entirely for TUI users.

#### Step 6: Implement `showLegend` and `showError`

Render legend as a persistent footer bar redrawn on command availability changes. Show errors in place (non-blocking flash) rather than "press Enter to continue" flow.

### Acceptance criteria

- [ ] `--tui` flag selects TuiRenderer, `--ascii` still works
- [ ] TuiRenderer implements all Facade vtable methods
- [ ] Takes terminal control on init, restores on deinit
- [ ] Board renders with active cell highlight (cursor position visible)
- [ ] Navigation moves cursor between cells via arrow keys
- [ ] Filling/clearing via digit/backspace keys updates board
- [ ] No ASCII parsing layer used — constructs Commands directly from keypresses
- [ ] Legend displays as persistent footer bar
- [ ] Errors display inline, non-blocking
- [ ] Graceful terminal cleanup on quit and signal interruption
- [ ] All existing 205+ tests still pass
