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
    newGameChoice_fn:   *const fn (*anyopaque) Error!NewGameChoiceResult,
    getCommandInput_fn: *const fn (*anyopaque, AvailableCommands) Error!ParseCommandResult
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

- **Dialog contract:** must return exactly one of three outcomes: `FileName` (owned path string), `Cancelled`, or an `Error`. The terminal implementation maps GUI file-save dialog behaviour onto stdin handling.
- **AsciiRenderer:** `saveDialog(self, default_name: []const u8) facade.Error!facade.SaveFileResult`. Mapping:
  - user types a name + Enter → `.FileName` with that string
  - empty input (just Enter) → `.FileName` with `default_name` (no cancel button; accepts prefilled default)
  - EOF / read error → `.Cancelled`
- **Facade:** saveDialog_fn field active, dispatcher routes through it.
- **Make(CT):** generates saveDialog_wrapper.


**- [x] Step 1f** — Add open dialog method.

- **Dialog contract:** must return exactly one of three outcomes: `FileName` (owned path string), `Cancelled`, or an `Error`. The terminal implementation maps GUI file-picker behaviour onto stdin handling.
- **AsciiRenderer:** `openDialog(self) facade.Error!facade.OpenFileResult`. Mapping:
  - user types a path + Enter → `.FileName` with that path
  - empty input (just Enter) → `.Cancelled`
  - EOF / read error → `.Cancelled`
- **Facade:** openDialog_fn field active, dispatcher routes through it.
- **Make(CT):** adds openDialog_wrapper.

**- [x] Step 1g** — Add `new` command to parser + stub `exec()` case. DONE this session (2026-08-14).

- **NewGameChoiceResult:** `union(enum) { Choice: NewGameChoice, Cancelled }` — mirrors the pattern of `SaveFileResult` / `OpenFileResult`. Keeps cancellation out of the actual game-starting choices.

- **Facade:** change `newGameOptions_fn` to return `Error!NewGameChoiceResult`, add dispatcher `newGameOptions()`.
- **AsciiRenderer:** implement `newGameOptions(self) facade.Error!facade.NewGameChoiceResult` — terminal renderer decides how to present choices.

- Notes: `FromUrl` and `PasteString` are reserved for WASM renderer (issue 03). Terminal never returns them.
- **Make(CT):** add `newGameOptions_wrapper`, wire `newGameOptions_fn` into `make()`.


**- [x] Step 1h** — Add command input method.

- **No CommandInput type.** Dropped. The facade methods return game domain types, not parse intermediaries.
- **AsciiRenderer:** `getCommandInput(self, avail: AvailableCommands) facade.Error!facade.ParseCommandResult`. Reads line -> trim -> calls `command.parseWithCommands()` with available command names. Returns the `ParseCommandResult` directly (no wrapper type).

  - valid command/parsed result -> returned directly
  - empty line       -> parse error ("empty input") — the loop shows it as an error and loops again
  - read EOF/error   -> treated as "quit" command (maps to `.Quit`)
- This moves prompt + parse logic into AsciiRenderer. Step 2 then replaces `out.print("> ") + readLine(in_)` with `facade.getCommandInput(avail)` in sudoku.zig.
- **Facade:** uncomment `getCommandInput_fn`, add dispatcher.
- **Make(CT):** add `getCommandInput_wrapper` + wire into `make()`.

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

- [x] `sudoku.zig` uses Renderer interface exclusively for all input and rendering — no direct stdin/stdout access
- [x] Step 1: All 7 facade methods implemented on AsciiRenderer with Facade dispatchers, Make(CT) wrappers, and tests
  - [x] render, showLegend, showError, saveDialog, openDialog, newGameOptions, getCommandInput
- [ ] Step 2: Wire Facade into sudoku.zig end-to-end
  - `main.zig` creates renderer through `Make(AsciiRenderer).make()` and passes Facade to Sudoku init
  - Every stdin read replaced with a Facade call (`getCommandInput`, `showError`, etc.)
  - `run()` no longer creates stdout_writer or stdin_reader
- [ ] Step 3: Adapt MockRenderer for testable widget-based flows
  - All 7 methods stubbable on MockRenderer with canned responses
  - ~10 existing sudoku.zig tests updated to create facades before init
  - Facade-driven integration tests for save/open command flows
## Blocked by
(none)
