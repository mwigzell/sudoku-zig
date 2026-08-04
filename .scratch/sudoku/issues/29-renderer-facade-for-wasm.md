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


#### Risks (tracked)

#### I/O Ownership Decisions (confirmed with user)

- **AsciiRenderer stores:** `io: std.Io`, `writer: *Io.Writer`, `allocator: std.mem.Allocator`, `styler: *StylerType`.
- **Reader NOT stored as pointer.** Zig readers wrap stack buffers (`reader(io, &buf)`). A stored reader pointer would point at a stale buffer after the call returns. Instead, each method that needs to read creates a local stack buffer + reader inline:
  ```zig
  var buf: [512]u8 = undefined;
  var in_ = Io.File.stdin().reader(self.io, &buf);
  const line = try in_.takeDelimiter('\n') orelse return error.ReadEOF;
  ```
- **readLine() helper on AsciiRenderer returns `Error!?[]u8`** — uses stored allocator to dupe the slice (Option A). Caller owns the string and must `defer self.allocator.free(line)`. No bare buffer param leaking through method signatures.
- **Why not caller-provided buffer?** Every prompt in this app is infrequent — maybe twice per command cycle max. The alloc/free overhead is nothing. Returns clean `[]u8` (standard Zig owned string pattern) instead of passing a buffer parameter through the Facade interface.
- **Facade methods don't leak allocator params.** Allocator belongs in init() once, not repeated on every facade call signature.

#### Vtable lessons proven (commit c4e63f2)

1. **`.interface` vtable bridge loses bytes on sequential small writes** — AsciiRenderer calls `self.writer.writeAll()` directly on the raw writer stored from init, not through `.interface`.
2. **`anytype` fields make structs non-@ptrCastable** — `Make(CT)` uses concrete `*CT`. AsciiRenderer holds `*Io.Writer` (concrete pointer) not `anytype`.
4. **Bare `fn` vs `*const fn`** — all facade fields use `*const fn` pointers (runtime-assignable), proven working in Make generator.

The proposed interface uses function pointers with a concrete error set and convenience dispatchers. Allocator, reader/writer handles are passed to the concrete renderer's `init()` once — never leak through facade method signatures.


```zig
pub const Error = error{OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied};

pub const Facade = struct {
    context: *anyopaque,
    render_fn:          *const fn (*anyopaque, BoardView, ?[]const u8) Error!void,
    showLegend_fn:      *const fn (*anyopaque, AvailableCommands) Error!void,
    showError_fn:       *const fn (*anyopaque, []const u8) Error!void,
    saveDialog_fn:      *const fn (*anyopaque, []const u8) Error!SaveFileResult,
    openDialog_fn:      *const fn (*anyopaque) Error!OpenFileResult,
    newGameOptions_fn:  *const fn (*anyopaque) Error!NewGameChoice,
    getCommandInput_fn: *const fn (*anyopaque, AvailableCommands) Error!CommandInput
};
```


### Implementation Steps

**Per-step pattern:** For each method 1b–1h we do three things together — add the instance method to AsciiRenderer, uncomment the corresponding field + dispatcher in Facade, and add the wrapper in `Make(CT)`. No separate files. The methods grow on AsciiRenderer itself.


**- [x] Step 1a** — Rename `RenderError` to `Error` in facade.zig. DONE (commit c4e63f2).

The Facade struct, shared types and convenience dispatchers remain. Allocator params removed from facade method signatures.

**- [x] Step 1b** — Board render method + vtable wiring. DONE (commit c4e63f2).

- **AsciiRenderer:** `render(self, view: BoardView, status_msg: ?[]const u8) anyerror!void`. Writes column header, borders, styled rows via stored writer. No `.interface` — direct `self.writer.writeAll()` calls.
- **Facade:** `render_fn` field active, `render()` dispatcher routes through it.
- **Make(CT):** generates `render_wrapper` that does @ptrCast -> *CT -> self.render(). make() wires context + render_fn.


**- [x] Step 1c** — Add legend display method. DONE (commit 320a048).

- **AsciiRenderer:** add `showLegend(self, commands: AvailableCommands) Error!void` — writes legend line to stored writer (currently `printLegend(out)` in sudoku.zig).
- **Facade:** uncomment showLegend_fn, add dispatcher `showLegend(commands)`.
- **Make(CT):** add showLegend_wrapper.


**- [x] Step 1d** — Add error modal method. DONE.


- **AsciiRenderer:** `showError(self, msg: []const u8) Error!void` prints message + "Press Enter to continue..." and waits on stdin reader (replaces `waitAck()`). Required adding `io: std.Io` field to AsciiRenderer struct so it can open stdin.
- **Facade:** `showError_fn` field active, `showError()` dispatcher routes through it.
- **Make(CT):** generates `showError_wrapper`.
- **Breaking change:** `AsciiRenderer.init()` signature changed from `init(writer, styler)` to `init(io, writer, styler)`. Updated main.zig and all existing tests.

**- [x] Step 1e** — Add save dialog method.

- **AsciiRenderer:** add `saveDialog(self, default_name: []const u8) Error!SaveFileResult` — prompts for filename via reader, returns owned string. Remembers last-used filename to skip repeated prompts (currently inline in promptForAndRunCommand).

- **AsciiRenderer:** `saveDialog(self, default_name: []const u8) Error!SaveFileResult` prompts stdin for filename, returns allocator-owned string. Empty input → uses default.
- **Facade:** uncomment saveDialog_fn, add dispatcher.
- **Make(CT):** add wrapper.


**- [ ] Step 1f** — Add open dialog method.

- **AsciiRenderer:** add `openDialog(self) Error!OpenFileResult`. Same prompt pattern as save. Returns owned path string.
- **Facade:** uncomment openDialog_fn, add dispatcher.
- **Make(CT):** add openDialog_wrapper.


**- [ ] Step 1g** — Add new-game options method.

- **AsciiRenderer:** add `newGameOptions(self) Error!NewGameChoice`. Menu keys 1-5, reads choice from stored reader, returns structured union.
- **Facade:** uncomment newGameOptions_fn, add dispatcher.
- **Make(CT):** add newGameOptions_wrapper.


**- [ ] Step 1h** — Add command input method.
- **AsciiRenderer:** add `getCommandInput(self, avail: AvailableCommands) Error!CommandInput`. Replaces current readLine + parsing. Reads text from stdin, parses against available commands, returns structured union (Fill/Clear/Quit/Undo/Redo/Save/Open/NewGame).
- **Facade:** uncomment getCommandInput_fn, add dispatcher.
- **Make(CT):** add getCommandInput_wrapper.


**- [ ] Step 2** — Wire Facade into sudoku.zig.

Once all 7 methods are on AsciiRenderer and wired through Make():
1. In `main.zig`: create renderer, wrap through Make(AsciiRenderer).make(), pass Facade to Sudoku init instead of raw pointer.
2. Remove `comptime R` parameter from `Sudoku(comptime R: type)`. Store *Facade not *R.
3. Replace every use of out/in_ in sudoku.zig methods with Facade calls:
   - `out.print("> ")` + `readLine(in_)` -> facade.getCommandInput(avail)
   - `printLegend(out)` -> facade.showLegend(avail)
   - `waitAck(out, in_, msg)` -> facade.showError(msg)

4. run() no longer creates stdout_writer or stdin_reader — it just loops calling Facade methods.


**- [ ] Step 3** — Adapt MockRenderer with canned responses.

All 7 facade methods implemented on MockRenderer for testing widget-based flows. Wired through Make(MockRenderer). Update ~10 test sites in sudoku.zig to create facades before init.


**- [ ] Step 4** — Baseline regression + coverage (post-step checkpoint).

All 182+ existing tests pass. zig build run produces visually identical output. This checkpoint will be re-verified after Steps 1h–3 complete.



### What this does NOT cover

- WASM browser renderer implementation (issue 03) — that consumes the facade later
- TuiRenderer with ncurses cursor control (issue 10) — separate rendering concern
- Polishing the UX per-palette (themes, icons) out of scope
## Acceptance criteria

- [x] Facade struct exists in `src/renderer/facade.zig` with shared types (`NewGameChoice`, `SaveFileResult`, `CommandInput`, etc.) and `Make(CT)` generator.
- [x] render() method wired: AsciiRenderer + Facade dispatcher + Make wrapper tested
- [ ] remaining 5 methods added to AsciiRenderer, Facade dispatchers uncommented, Make wrappers generated
## Blocked by
(none)
