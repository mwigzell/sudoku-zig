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

The command loop no longer reads stdin. It calls structured facade methods and gets structured data back — never raw strings from a prompt.

### Current problem (why this is needed)

`sudoku.zig` reads directly from `Io.File.stdin().reader`. WASM has no stdin, so user input must flow through the same abstraction layer as output. Today all UI besides board rendering is ad-hoc in `sudoku.zig`:

- `readLine()` — raw stdin for commands
- `waitAck()` — press Enter after errors
- inline save filename prompt inside `promptForAndRunCommand`
- `printLegend()` — writes directly to stdout writer

### Design Decision: Option B (Vtable Facade with Auto-Wrapping Generator)
The interface is a **vtable struct** with function pointers and `*anyopaque` context — not duck typing.

| Reason | Detail |
|---|---|
| Concrete error set | Uses `Error` instead of `anyerror` (Zig 0.17 requires explicit error-set unions at every call site with anyerror) |
| No call_stdcall | Default Zig calling convention throughout; call_stdcall is x86-specific and wrong for WASM target |
| Auto-wrapping generator | `Make(comptime CT)` auto-generates a vtable from any concrete renderer type — no manual wiring per renderer |

#### Risks (tracked)

1. **Bare `fn` fields make struct comptime-only:** RESOLVED. The Facade struct fields used bare `fn` which made the entire struct comptime-only (bare `fn` is a first-class function type, not a pointer). Fix: all 7 fn pointer fields use `*const fn`. Also fixed missing comma after `context: *anyopaque`. No other workaround needed.
2. **~10 test sites in sudoku.zig** need facade creation before `init()` calls — compiler errors will be explicit on breakage.
3. **AsciiRenderer currently only holds a writer** — the 6 new facet methods (saveDialog, showError, etc.) eventually need reader access too. Threading that through is deferred to Step 3 when sudoku.zig wires them up for real.


The proposed interface uses function pointers with a concrete error set and convenience dispatchers:

```zig
pub const Error = error{OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied};

pub const Facade = struct {
    context: *anyopaque,
    render_fn:         *const fn (*anyopaque, BoardView, ?[]const u8) Error!void,
    showLegend_fn:     *const fn (*anyopaque, AvailableCommands) Error!void,
    showError_fn:      *const fn (*anyopaque, []const u8) Error!void,
    saveDialog_fn:     *const fn (*anyopaque, []const u8, std.mem.Allocator) Error!SaveFileResult,
    openDialog_fn:     *const fn (*anyopaque, std.mem.Allocator) Error!OpenFileResult,
    newGameOptions_fn: *const fn (*anyopaque, std.mem.Allocator) Error!NewGameChoice,
    getCommandInput_fn: *const fn (*anyopaque, AvailableCommands, std.mem.Allocator) Error!CommandInput
};
```


### Implementation Steps

**- [x] Step 1** — Define `Facade` + `Make(comptime CT)` generator in `src/renderer/facade.zig`.
Replace the `Renderer(comptime RT)` stub. The file contains: `Error`, the shared types, the `Facade` struct with 7 function-pointer fields plus convenience dispatchers, and `Make(comptime CT)` auto-wrapping generator. Compile check — no test implementations yet.

**- [ ] Step 2** — Adapt AsciiRenderer to implement the facade.

Add all 7 facade methods to `AsciiRenderer`. The `render()` method is updated to accept optional `status_msg`. The other 6 methods (showLegend, showError, saveDialog, openDialog, newGameOptions, getCommandInput) are wired as stubs returning safe defaults so existing tests don't break. Use the `Make` generator. Update `main.zig` to create a facade from AsciiRenderer and pass it through.

**- [ ] Step 3** — Adapt MockRenderer with canned response support.

Add canned response fields/indices for save, open, newGame, and command methods so tests can drive widget-based flows. All 7 facade methods implemented; use the `Make` generator. Update ~10 test sites in `sudoku.zig` to create facades before `init()` calls.

**- [ ] Step 4** — Rewrite `sudoku.zig` command loop through `Facade`.
Remove `comptime R` parameter from `Sudoku()`. Change `renderer: *R` field to `*Facade`. Call sites stay visually the same (via convenience dispatchers). All I/O paths previously reading stdin directly now route through facade methods.

**- [ ] Step 5** — Regression + coverage.
All 179+ existing tests pass. `zig build run` produces visually identical output. `zig build cov` shows no regression.
### What this does NOT cover

- WASM browser renderer implementation (issue 03) — that consumes the facade later
- TuiRenderer with ncurses cursor control (issue 10) — separate rendering concern
- Polishing the UX per-palette (themes, icons) out of scope

## Acceptance criteria

- [x] Facade interface exists in `src/renderer/facade.zig` defining all seven methods plus shared types (`NewGameChoice`, `SaveFileResult`, etc.)
- [ ] AsciiRenderer implements the facade with identical terminal behaviour to today
- [ ] `sudoku.zig` no longer reads stdin directly — all I/O flows through the facade
- [ ] MockRenderer supports canned responses returning structured types for testing widget-based flows
- [ ] All 179+ existing tests pass
- [ ] `zig build run` output is visually identical to pre-refactor
## Blocked by
(none)
