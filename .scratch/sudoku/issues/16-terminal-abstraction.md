Status: needs-triage

## Working mode
HITL. Design first; implementation when 15.5 sub-issues are clear.

## Parent
`.scratch/sudoku/prd.md`

## What to build
Introduce a `Terminal` seam so AsciiRenderer can target different output modes (plain ASCII vs. ANSI escape codes) without changing rendering logic.

Currently the renderer writes directly to an `Io.Writer`. Adding bold/red/colour for givens, conflicts, selections etc. means mixing terminal-specific escape sequences into the renderer — or not if running in tests / CI where raw output matters.

Zig doesn't have inheritance, so composition is the way to parameterize emission style:

```zig
const Terminal = struct {
    fn writeChar(self: *Terminal, ch: u8) !void;
    fn beginBold(self: *Terminal) !void;
    fn endStyle(self: *Terminal) !void;
    fn beginRed(self: *Terminal) !void;
};
```

Two concrete implementations from day one:
| Type | Writes raw chars | Escape codes | Use case |
|------|-----------------|-------------|----------|
| `PlainTerminal` (current behaviour) | ✓ | no-ops | tests, validation, CI |
| `AnsiTerminal` | ✓ | CSI codes (`\033[1m`, `\033[31m`, etc.) | production / default |

Renderer logic stays identical — only the emission layer differs. This is the same pattern we used for `IoSink` in issue 15.4.

### Scope
- Design the Terminal interface shape (what style methods are needed)
- Implement PlainTerminal and AnsiTerminal
- Wire AsciiRenderer through Terminal instead of writing values directly to the writer buffer
- Default to AnsiTerminal in prod; PlainTerminal in tests
- Ensure all 32+ renderer tests pass against PlainTerminal

### Not in scope
- Colour theme / palette selection
- Terminal capability detection (tput, etc.) — hardcode for now
- Selection cursor rendering (that's a UI concern further down)

## Acceptance criteria
- [ ] `Terminal` concept defined as a struct with style-emission methods
- [ ] PlainTerminal renders identically to current AsciiRenderer output
- [ ] AnsiTerminal produces bold/style wrapping around cell content
- [ ] Full renderer test suite passes against PlainTerminal (validates visual output unchanged)
- [ ] Production path defaults to AnsiTerminal

## Blocked by
Issue 15.5 resolution

## Comments
